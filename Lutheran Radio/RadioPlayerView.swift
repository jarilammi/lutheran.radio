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
/// - SeeAlso: ``beginObserving()``, ``handle(_:)``, `SharedPlayerManager.events`,
///   ``PlayerEvent``, `PlaybackIntent`, `WidgetEventObserver`,
///   `RadioPlayerView`, `PlayerViewModel`,
///   docs/Event-Driven-Refactor-Roadmap.md,
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
    ///   main actor as events arrive.
    /// - Important: This is additive. Starting observation has no effect on the
    ///   emitter, on other subscribers (WidgetRefreshManager, etc.), or on any
    ///   imperative playback paths.
    /// - Note: Because `events` currently provides no replay, events emitted before
    ///   `beginObserving` are not seen (matching the contract used by other Tier 2
    ///   consumers).
    /// - SeeAlso: `WidgetEventObserver.beginObserving(_:onElement:onTermination:)`,
    ///   SharedPlayerManager.`events`.
    func beginObserving() async {
        eventObserver.cancel()

        guard !SharedPlayerManager.isWidgetProcess() else { return }

        // Seed from SSOT so the first onChange sites see a current value even if
        // no new event is emitted immediately after the view appears.
        lastObservedIntent = await SharedPlayerManager.shared.currentPlaybackIntent

        let stream = await SharedPlayerManager.shared.events
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
    ///   instance until the next `beginObserving`.
    func cancel() {
        eventObserver.cancel()
    }

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
             .streamDidFail, .metadataDidUpdate, .visualStateDidChange,
             .persistedWidgetStateDidUpdate:
            // React to all other key state-transition events as required.
            // The count change is the value that can drive generic UI refresh sites.
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
/// Accessibility:
/// - `accessibilityIdentifier("volumeSlider")` is set on the inner `UISlider` of the
///   `MPVolumeView` (see `SystemVolumeRepresentable.makeUIView`) to keep the existing
///   `app.sliders["volumeSlider"]` UI tests passing without modification.
/// - Label and hint forwarded from Localizable (all 21 languages) on the SwiftUI wrapper.
/// - The underlying `MPVolumeView` / its slider supplies its own adjustable trait, current
///   value, and live announcements when volume changes via hardware or gestures.
///
/// - Important: This is the canonical volume surface for the SwiftUI player chrome.
/// - Note: `DirectStreamingPlayer.setVolume` is intentionally not called from this row and
///   remains untouched for potential legacy or other internal gain uses.
/// - SeeAlso: `SystemVolumeSlider`, `AirPlayButton`, `RadioPlayerView`,
///   `MPVolumeView.configureAsVolumeSliderOnly`, CODING_AGENT.md (Documentation & Comment Standards for AI Coding Agents),
///   <doc:Architecture>
struct VolumeAndAirPlayRow: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
                .font(.callout)
                .accessibilityHidden(true)

            SystemVolumeSlider()
                .accessibilityLabel(String(localized: "accessibility_label_volume", table: "Localizable"))
                .accessibilityHint(String(localized: "accessibility_hint_volume", table: "Localizable"))

            // AirPlay route picker (native, kept exactly as implemented).
            AirPlayButton()
        }
        .frame(height: 44)
    }
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
/// Accessibility is attached by the caller (`VolumeAndAirPlayRow`) so that identifier,
/// label, and hint can be centralized while the inner control retains its value behavior.
///
/// - Precondition: Must be used on the main actor / main thread (standard for all
///   UIViewRepresentable in SwiftUI). The hosting `UIHostingController` guarantees this.
/// - Postcondition: After insertion, user gestures and external volume changes are reflected
///   live in the slider and affect audible output level for the current route.
/// - Note: This type is intentionally simple. The only subview walk performed is a one-time
///   assignment of the accessibility identifier onto the child UISlider strictly to preserve
///   UI test compatibility (see implementation in makeUIView). No KVO, no observers, and
///   no hidden `MPVolumeView` instances are used.
/// - SeeAlso: `VolumeAndAirPlayRow`, `AirPlayButton`, `MPVolumeView` (MediaPlayer),
///   CODING_AGENT.md, <doc:Architecture>
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
/// Implementation notes:
/// - Route button suppressed via dedicated helper (no direct use of deprecated `showsRouteButton` property at the call site).
/// - Tint applied once in `makeUIView`; `MPVolumeView` does not require per-update tint pushes.
/// - `updateUIView` is intentionally a no-op. The control is live and self-managed.
/// - No force-unwraps, no `!`, no unsafe bridging. Pure value-type configuration.
///
/// This type is file-private; the public surface is `SystemVolumeSlider`.
private struct SystemVolumeRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView()
        volumeView.configureAsVolumeSliderOnly()
        // Bridge SwiftUI accentColor (AccentColor.colorset) to match the visual treatment
        // that the prior custom Slider received from .tint(.accentColor).
        volumeView.tintColor = UIColor(Color.accentColor)

        // Make the MPVolumeView itself carry the identifier (for otherElements / descendant queries)
        // and attempt to forward to its child UISlider (for legacy slider queries).
        volumeView.accessibilityIdentifier = "volumeSlider"

        // Assign the accessibility identifier to the underlying UISlider so that
        // XCUITest queries of the form `app.sliders["volumeSlider"]` continue to
        // locate the control (testVolumeSliderExists and similar) where possible.
        // MPVolumeView's volume indicator is implemented as a private UISlider subclass;
        // the walk is performed to maximize compatibility.
        //
        // This is a one-time configuration walk (no KVO, no observation, no hidden
        // listeners) performed only to preserve the existing UI test contract.
        // It is the minimal intervention that avoids changing the UITest while
        // using the real system volume control.
        if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            slider.accessibilityIdentifier = "volumeSlider"
        }
        return volumeView
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        // Intentionally empty: MPVolumeView observes AVAudioSession and updates itself.
        // External mutations are not performed from SwiftUI state.
    }
}

/// UIViewRepresentable wrapper for the native AirPlay picker button.
///
/// Prioritizes audio-only routes (video devices disabled) to match historical behavior.
struct AirPlayButton: View {
    var body: some View {
        AirPlayPickerView()
            .frame(width: 44, height: 44)
            .accessibilityLabel(String(localized: "accessibility_label_airplay", table: "Localizable"))
            .accessibilityHint(String(localized: "accessibility_hint_airplay", table: "Localizable"))
    }
}

private struct AirPlayPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
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
