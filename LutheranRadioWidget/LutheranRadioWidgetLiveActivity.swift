//
//  LutheranRadioWidgetLiveActivity.swift
//  LutheranRadioWidget
//
//  Created by Jari Lammi on 3.6.2025.
//

// SHARED: Cross-target source (main app + LutheranRadioWidgetExtension)
//
// Single physical file on disk, compiled into both targets via Xcode
// File System Synchronized Group + membershipExceptions (see project.pbxproj).
//
// Purpose:
// Live Activity (Dynamic Island + Lock Screen) view implementation and its
// AppIntent handlers. Renders `LutheranRadioLiveActivityAttributes.ContentState`
// (visualState + streamMetadata) provided by `RadioLiveActivityManager` using
// the `PersistedWidgetState` snapshot as the source.
//
// Key invariants:
// - All display data (visual state, language, metadata, hasError) flows exclusively
//   through the `PersistedWidgetState` snapshot / attributes ContentState.
//   `preferredWidgetLanguage()`, `streamForLanguageCode()`, `loadSharedState()`,
//   and `loadPersistedWidgetState()` are the readers.
// - Explicit user actions (play/pause toggle, language switch) must route through
//   `SharedPlayerManager.userRequestedPlay()` / `switchToStream(...)` (see
//   LiveActivityTogglePlaybackIntent for the explicit-play contract).
// - Helper functions and layout delegate to `WidgetDisplayModels` (the display
//   model SSOT) for program title, speaker line, emphasis, language names, and flags.
// - Privacy gate (`hasActiveWidgets` / no snapshot after clear) is respected by
//   callers; this file gracefully renders `.prePlay`-style neutral UI when state
//   is absent.
// - This file contains *no* security, certificate, or DNS logic. Security lives
//   exclusively in `Core/` (see CODING_AGENT.md "Core Framework Surface Area").
//
// Presentation surfaces (snapshot-driven, all three derived once at the top level):
// - Status indicator: `makeStatusPresentation()` → `PlayerStatusPresentation`.
//   Computed at top of `LockScreenLiveActivityView.body` and once inside the outer
//   `dynamicIsland` closure; all expanded, compact, and minimal regions close over
//   the hoisted value (no inline re-derivation inside region builders).
// - Primary control: `makeControlPresentation()` → `PlayerControlPresentation`.
//   Computed once per view/closure and closed over by play/pause buttons.
// - Metadata/emphasis: `widgetNowPlayingDisplayModel(...)` → `WidgetNowPlayingDisplayModel`.
//   Computed once at the top of Lock Screen body and outer Dynamic Island; the narrow
//   model (programTitle, speakerLine, speakerVisible, emphasis) is passed into
//   `.center`, `compactLeading`, and the Lock Screen metadata blocks.
//
// For Live Activities, two small derived values are also computed once near the top
// of the outer `dynamicIsland` closure and once at the top of `LockScreenLiveActivityView.body`:
// - `isPlaying` (from `isActivelyPlaying`): drives LIVE indicator, animation bars,
//   radio glyph background, and the compact title visibility. Regions close over it.
// - `radioIconTint` (from `buttonTintColor.swiftUIColor`): non-control decorative tint
//   for the radio glyph in .leading and compactLeading.
//
// `isActivelyPlaying` (and `buttonTintColor` for non-control radio glyphs) remain on
// `PlayerVisualState` exclusively for semantic / presence decisions (LIVE dot, bars,
// "Local Only", resurrection, intent branching). Pure control glyph+tint decisions
// must use the narrow `PlayerControlPresentation`. See PlayerVisualState.swift header.
//
// - SeeAlso: `LutheranRadioLiveActivityAttributes`, `SharedPlayerManager`
//   (PersistedWidgetState, load*/persist*, userRequestedPlay, preferredWidgetLanguage),
//   `PlayerVisualState` (the three mappers + `isActivelyPlaying` semantics),
//   `PlayerStatusPresentation`, `PlayerControlPresentation`, `WidgetNowPlayingDisplayModel`,
//   `widgetNowPlayingDisplayModel(...)`, `WidgetDisplayModels.swift`,
//   `LutheranRadioWidget.swift` (SimpleEntry + Provider snapshot pattern; the widget
//   counterpart that stores the three narrow surfaces on the TimelineEntry),
//   `RadioLiveActivityManager`,
//   CODING_AGENT.md (Single Source of Truth Principles, Cross-target shared source files,
//   narrow inputs for WidgetKit/ActivityKit, Documentation & Comment Standards),
//   docs/Widget-Presentation-Dataflow.md (primary reference for derivation sites,
//   why hoisting matters for region invalidation, semantic vs presentation division),
//   <doc:Architecture>, README.md.
//
// AGENT NOTE: This is presentation + intent surface only. State mutations belong
// in SharedPlayerManager. When editing views or intents, keep the explicit-play
// rule (userRequestedPlay for toggle "play" direction) and the fixed-metadata
// region contract (no conditional row insertion) intact.

import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents
import WidgetSurface

// MARK: - Live Activity Helpers
//
// Status, control, and metadata/emphasis are all obtained from the narrow presentation
// surfaces (`makeStatusPresentation`, `makeControlPresentation`, and
// `widgetNowPlayingDisplayModel`). Call sites derive once at the top of the relevant
// view or outer Dynamic Island closure and close over the narrow values.
//
// In Live Activities, small derived values (`isPlaying`, `radioIconTint`) are also
// computed once near the top of `LockScreenLiveActivityView.body` and once inside
// the outer `dynamicIsland` closure, then closed over by all region builders.
// This eliminates repeated direct reads of `visualState.isActivelyPlaying` and
// `visualState.buttonTintColor` for pure visual decisions (LIVE indicator, bars,
// decorative radio glyph tint/background) while keeping semantic/policy reads
// (intents, resurrection) on the source.
//
// See the file header for the exact division and
// docs/Widget-Presentation-Dataflow.md for the full snapshot-driven contract.
//
// Language, flag, and alternative-stream helpers delegate to WidgetDisplayModels.

/// Returns the localized display name for a language code (e.g. "English").
///
/// Forwards to the shared implementation in `WidgetDisplayModels.displayLanguageName(for:)`,
/// which prefers `SharedPlayerManager.availableStreams` (the 21-language source of truth)
/// and falls back to established localized keys. This keeps names consistent between
/// widgets, Live Activity, and previews.
///
/// - SeeAlso: `displayLanguageName(for:)`, `SharedPlayerManager.streamForLanguageCode`.
private func getLanguageName(_ code: String) -> String {
    displayLanguageName(for: code)
}

/// Returns the flag emoji for a language code.
///
/// Forwards to `WidgetDisplayModels.displayFlag(for:)`.
private func getStreamFlag(_ code: String) -> String {
    displayFlag(for: code)
}

/// Returns up to 4 alternative language codes for the quick-switch row (excluding current).
///
/// Prefers the authoritative `SharedPlayerManager.availableStreams` (full 21 languages)
/// so every supported language can appear as a switch target when it is not the active one.
/// Falls back to the legacy curated set only if the streams list is empty (defensive).
///
/// - Important: The count is capped at 4 for layout reasons in both the DI center region
///   (horizontal ScrollView) and the Lock Screen row (fixed HStack).
/// - SeeAlso: ``SharedPlayerManager/availableStreams``, `preferredWidgetLanguage()`.
private func getAlternativeStreams(current: String) -> [String] {
    let streams = SharedPlayerManager.shared.availableStreams
    let codes = streams.map { $0.languageCode }
    if !codes.isEmpty {
        return Array(codes.filter { $0 != current }.prefix(4))
    }
    // Legacy small set fallback (never reached on normal runs).
    let fallback = ["en", "de", "fi", "sv", "et"]
    return Array(fallback.filter { $0 != current }.prefix(4))
}

// Unified program title + speaker resolver lives in WidgetDisplayModels.swift
// (WidgetMetadataEmphasis + `widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)`).
//
// Snapshot-driven / top-level derivation:
// - Live Activity computes the model once at the top of LockScreenLiveActivityView.body
//   and once inside the outer dynamicIsland closure (using the current preferred language
//   for the fallback name).
// - The narrow `WidgetNowPlayingDisplayModel` (programTitle, speakerLine, speakerVisible,
//   emphasis) is then closed over and supplied to the metadata blocks in .center and
//   compactLeading (and the Lock Screen view) instead of re-calling the function
//   inside each region builder.
// - This is the ActivityKit counterpart to storing `widgetNowPlayingDisplayModel` on
//   `SimpleEntry` for the home-screen widgets. See WidgetDisplayModels.swift header
//   for the full invalidation-surface rationale.

// MARK: - Live Activity Intents
//
// Privacy note (SSOT + privacy gate):
// Live Activities read state via the `PersistedWidgetState` snapshot carried in
// `LutheranRadioLiveActivityAttributes.ContentState` (or `loadSharedState()` fallbacks).
// After `clearAllLocalState()` (or when `WidgetRefreshManager.hasActiveLutheranWidgets == false`
// because no Lutheran widget/Control Center widget is installed), no snapshot is written
// and the Live Activity ends; subsequent presentations fall back to neutral prePlay-like UI.
//
// All writes are gated in SharedPlayerManager via `hasActiveWidgets` (with an
// `isWidgetProcess()` bypass only during AppIntent execution). See:
// - `WidgetRefreshManager.hasActiveLutheranWidgets` (the single source of truth for the gate)
// - `persistWidgetSnapshot`, `savePersistedWidgetState`, `writeInstantFeedback`, etc.
//
// See also the resurrection and persistence tables in SharedPlayerManager.swift.

/// AppIntent that toggles playback when the user taps the play/pause button
/// inside the Live Activity (Dynamic Island trailing region or Lock Screen row).
///
/// - Important: The "play/resume" direction (when `!isActivelyPlaying`) **must**
///   call `SharedPlayerManager.userRequestedPlay()`. This is the single
///   authoritative explicit-play entry point. It ensures `setUserIntentToPlay()`
///   executes before any resurrection/one-shot/sticky-intent logic inside `play()`.
///   The pause direction calls `stop()` directly (the correct path for immediate
///   sticky `.userPaused`).
///
///   Explicit user-initiated play requests (from Live Activity, home widget,
///   Control widget, Siri, remote commands, URL schemes, etc.) are semantically
///   different from internal continuation/resumption. Only internal paths are
///   allowed to call `play()` directly after a prior `userRequestedPlay()` has
///   already established intent (see the resume branches inside
///   `completeStreamSwitch` and `switchToStreamFromWidget`).
///
/// - SeeAlso: ``SharedPlayerManager/userRequestedPlay()``,
///   ``SharedPlayerManager/play()``, ``SharedPlayerManager/stop()``,
///   `LiveActivitySwitchStreamIntent`, <doc:Architecture>,
///   CODING_AGENT.md (Single Source of Truth Principles + Cross-target shared sources).
///
/// AGENT NOTE: Live Activity intents often run in a short-lived extension process
/// whose memory-only session snapshot is empty. Direction is planned by
/// ``WidgetIntentExecution/performLiveActivityToggle()`` from ActivityKit
/// ContentState / durable App Group mirror first, then actor/snapshot fallbacks —
/// never from bare default `.prePlay` alone. Treat play as an explicit user surface:
/// always go through `userRequestedPlay()` for the "start playing" direction.
/// Direct `play()` calls here would bypass the intent-setting guard and are forbidden.
struct LiveActivityTogglePlaybackIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Toggle Lutheran Radio Playback" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Toggle play/pause from Live Activity.")
    }
    
    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[LutheranRadioWidgetLiveActivity] LiveActivityTogglePlaybackIntent.perform called")
        #endif

        // AGENT NOTE: Full path is ``WidgetIntentExecution/performLiveActivityToggle()``.
        // Plans from Live Activity ContentState / durable App Group mirror first — not only
        // extension-local currentVisualState (empty session under home-widget write suppression
        // used to invert the first lock-screen pause into play).
        await WidgetIntentExecution.performLiveActivityToggle()

        #if DEBUG
        print("[LutheranRadioWidgetLiveActivity] LiveActivityTogglePlaybackIntent completed")
        #endif

        return .result()
    }
}

/// AppIntent for switching the active stream/language directly from the Live Activity
/// quick-switch buttons (Dynamic Island center region or Lock Screen language row).
///
/// The `languageCode` parameter is supplied by the `ForEach` over the result of
/// `getAlternativeStreams(current:)`. The implementation looks up the canonical
/// `DirectStreamingPlayer.Stream` via the authoritative `availableStreams` list
/// (never constructs one locally) and calls `switchToStream`, which is the
/// single correct path for language changes (it resets prePlay, preserves intent
/// correctly, and updates the PersistedWidgetState snapshot).
///
/// - SeeAlso: ``SharedPlayerManager/switchToStream(_:)``,
///   ``SharedPlayerManager/availableStreams``, `getAlternativeStreams`,
///   `LiveActivityTogglePlaybackIntent`, CODING_AGENT.md.
struct LiveActivitySwitchStreamIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Switch Stream" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Switch to a different language stream from Live Activity.")
    }
    
    @Parameter(title: "Language Code")
    var languageCode: String
    
    init() {}
    init(languageCode: String) {
        self.languageCode = languageCode
    }

    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[LutheranRadioWidgetLiveActivity] LiveActivitySwitchStreamIntent.perform called for language: \(languageCode)")
        #endif

        // AGENT NOTE: Full path is ``WidgetIntentExecution/performLiveActivityStreamSwitch(languageCode:)``.
        let switched = await WidgetIntentExecution.performLiveActivityStreamSwitch(languageCode: languageCode)

        #if DEBUG
        if !switched {
            print("[LutheranRadioWidgetLiveActivity] LiveActivitySwitchStreamIntent: Language stream not found")
        } else {
            print("[LutheranRadioWidgetLiveActivity] LiveActivitySwitchStreamIntent completed for \(languageCode)")
        }
        #endif

        return .result()
    }
}

/// The WidgetKit definition for the Lutheran Radio Live Activity.
///
/// Registers an `ActivityConfiguration` supplying Lock Screen + Dynamic Island
/// presentations. ContentState snapshots are pushed by `RadioLiveActivityManager`.
/// All three narrow presentation surfaces (status + control + metadata) are derived
/// once at the top of the rendered views / outer closures using the canonical mappers.
///
/// - Important: The widget kind `"LutheranRadioLiveActivity"` must match the
///   kind used when starting/ending activities in `RadioLiveActivityManager`.
/// - SeeAlso: `LutheranRadioLiveActivityAttributes`, `LockScreenLiveActivityView`,
///   `RadioLiveActivityManager`, docs/Widget-Presentation-Dataflow.md,
///   CODING_AGENT.md (Cross-target shared source files).
struct LutheranRadioLiveActivityWidget: Widget {
    let kind: String = "LutheranRadioLiveActivity"

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LutheranRadioLiveActivityAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
                .widgetURL(URL(string: "lutheranradio://open"))
        } dynamicIsland: { context in
            // Derive narrow presentation surfaces once at the outer Dynamic Island closure
            // (the ActivityKit counterpart to Provider pre-derivation into SimpleEntry).
            // All Dynamic Island regions and compact variants close over these values.
            //
            // - statusPres: narrow PlayerStatusPresentation for status text + indicator colors
            //   (via makeStatusPresentation). Used by expanded .center, .bottom, and minimal.
            // - controlPres: narrow PlayerControlPresentation for play/pause glyph + tint
            //   (via makeControlPresentation). Used by trailing and compactTrailing buttons.
            // - metadataModel: narrow WidgetNowPlayingDisplayModel for program title + speaker.
            //   Used by center and compactLeading.
            // - isPlaying + radioIconTint: small derived values for pure visual decisions
            //   (LIVE indicator presence, animation bars, radio glyph background/tint in
            //   non-control decorative positions). These reduce repeated direct reads of
            //   context.state.visualState inside independent region builders.
            //
            // Semantic uses of isActivelyPlaying remain on the source (intents, resurrection
            // policy). Non-control decorative buttonTintColor reads are intentionally kept
            // (see PlayerVisualState.swift header and docs/Widget-Presentation-Dataflow.md).
            //
            // - SeeAlso: docs/Widget-Presentation-Dataflow.md (Live Activity derivation
            //   pattern), `PlayerControlPresentation`, `WidgetNowPlayingDisplayModel`,
            //   `LutheranRadioWidget.swift` (SimpleEntry parallel), CODING_AGENT.md.
            let statusPres = context.state.visualState.makeStatusPresentation()
            let controlPres = context.state.visualState.makeControlPresentation()

            let currentLanguageForMetadata = SharedPlayerManager.preferredWidgetLanguage()
            let languageNameForMetadata = SharedPlayerManager.streamForLanguageCode(currentLanguageForMetadata).language
            let metadataModel = widgetNowPlayingDisplayModel(
                visualState: context.state.visualState,
                streamMetadata: context.state.streamMetadata,
                languageName: languageNameForMetadata
            )

            // Small derived presentation flags (hoisted once, closed over by all regions).
            // Keeps region closures trivial and bounds visualState reads to this site.
            let isPlaying = context.state.visualState.isActivelyPlaying
            let radioIconTint = context.state.visualState.buttonTintColor.swiftUIColor

            // Explicit return required once the closure body contains statements (let bindings)
            // before the DynamicIsland builder expression. The multi-trailing-closure call
            // no longer qualifies as an implicit-return single-expression closure.
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        ZStack {
                            // Background tint for radio glyph: green when actively playing, gray otherwise.
                            // Uses hoisted `isPlaying` (derived once above) instead of re-reading visualState.
                            Circle()
                                .fill(isPlaying ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                                .frame(width: 32, height: 32)
                            
                            // Non-control decorative radio icon tint (per PlayerVisualState policy for
                            // buttonTintColor outside primary controls). Uses hoisted `radioIconTint`.
                            Image(systemName: "radio")
                                .foregroundColor(radioIconTint)
                                .font(.system(size: 16, weight: .medium))
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey("lutheran_radio_title"))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            HStack(spacing: 4) {
                                Text(getStreamFlag(SharedPlayerManager.preferredWidgetLanguage()))
                                    .font(.caption2)
                                Text(getLanguageName(SharedPlayerManager.preferredWidgetLanguage()))
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                            }
                            
                            // LIVE indicator presence driven by hoisted isPlaying (pure visual decision).
                            // The actual semantic "actively streaming" flag lives on PlayerVisualState.
                            if isPlaying {
                                HStack(spacing: 2) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 4, height: 4)
                                        .opacity(0.8)
                                    Text(String(localized: "LIVE", defaultValue: "LIVE", table: "Localizable"))
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.red)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(spacing: 8) {
                        Button(intent: LiveActivityTogglePlaybackIntent()) {
                            ZStack {
                                // Control button exclusively uses the once-computed narrow controlPres
                                // (glyph + tint). This is the canonical pattern for play/pause affordances.
                                Circle()
                                    .fill(controlPres.tint.opacity(0.2))
                                    .frame(width: 44, height: 44)
                                
                                Image(systemName: controlPres.systemImage)
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .foregroundColor(controlPres.tint)
                            }
                        }
                        .buttonStyle(.plain)
                        
                        // Equalizer-style animation bars: presence is a visual decision driven by the
                        // hoisted `isPlaying` value (computed once at outer closure). Animation value
                        // uses the stable isPlaying Boolean to avoid capturing the whole visualState.
                        if isPlaying {
                            HStack(spacing: 2) {
                                ForEach(0..<3, id: \.self) { index in
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.green)
                                        .frame(width: 2, height: CGFloat.random(in: 4...12))
                                        .animation(.easeInOut(duration: Double.random(in: 0.3...0.7)).repeatForever(autoreverses: true), value: isPlaying)
                                }
                            }
                        }
                    }
                }
                
                DynamicIslandExpandedRegion(.center) {
                    // statusPres and metadataModel are computed once at the outer dynamicIsland level.
                    VStack(spacing: 6) {
                        VStack(spacing: 2) {
                            Text(statusPres.text)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(statusPres.foreground)
                            
                            // Fixed metadata region (no conditional insertion) using the outer-derived narrow model.
                            Text(metadataModel.programTitle)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.center)
                                .opacity(metadataModel.emphasis.opacity)
                                .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 22, alignment: .center)
                            
                            Text(metadataModel.speakerLine)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .opacity(metadataModel.speakerVisible ? metadataModel.emphasis.opacity : 0)
                                .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 14, alignment: .center)
                        }
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(getAlternativeStreams(current: SharedPlayerManager.preferredWidgetLanguage()), id: \.self) { langCode in
                                    Button(intent: LiveActivitySwitchStreamIntent(languageCode: langCode)) {
                                        VStack(spacing: 2) {
                                            Text(getStreamFlag(langCode))
                                                .font(.system(size: 16))
                                            Text(getLanguageName(langCode))
                                                .font(.system(size: 8, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.gray.opacity(0.1))
                                        .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        // Status indicator closes over the hoisted statusPres from the outer closure.
                        HStack(spacing: 4) {
                            Circle()
                                .fill(statusPres.background)
                                .frame(width: 6, height: 6)
                            Text(statusPres.text)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // Animation bars (or "Local Only" privacy label) use the hoisted `isPlaying`.
                        // This is a pure presentation decision; the bars are decorative equalizer UI.
                        // "Local Only" appears only when not actively playing (semantic presence).
                        if isPlaying {
                            HStack(spacing: 1) {
                                ForEach(0..<5, id: \.self) { index in
                                    RoundedRectangle(cornerRadius: 0.5)
                                        .fill(LinearGradient(
                                            gradient: Gradient(colors: [.green, .blue]),
                                            startPoint: .bottom,
                                            endPoint: .top
                                        ))
                                        .frame(width: 2, height: CGFloat.random(in: 3...10))
                                        .animation(
                                            .easeInOut(duration: Double.random(in: 0.3...0.8))
                                            .repeatForever(autoreverses: true)
                                            .delay(Double(index) * 0.1),
                                            value: isPlaying
                                        )
                                }
                            }
                        } else {
                            HStack(spacing: 2) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(.green)
                                Text(LocalizedStringKey("Local Only"))
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
            } compactLeading: {
                // Language name resolution for metadataModel is performed once in the outer
                // dynamicIsland closure. compactLeading only consumes the already-derived model
                // plus the hoisted `isPlaying` / `radioIconTint` for its visual decisions.
                HStack(spacing: 2) {
                    ZStack {
                        // Circle background and radio glyph use hoisted values (single read site
                        // at top of closure). Matches the pattern used in .leading.
                        Circle()
                            .fill(isPlaying ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                            .frame(width: 20, height: 20)
                        
                        Image(systemName: "radio")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(radioIconTint)
                    }
                    
                    // Compact animation bars + program title appear only while playing.
                    // Decision uses hoisted isPlaying (visual presence), not repeated visualState read.
                    if isPlaying {
                        HStack(spacing: 1) {
                            ForEach(0..<2, id: \.self) { index in
                                RoundedRectangle(cornerRadius: 0.5)
                                    .fill(Color.green)
                                    .frame(width: 1, height: CGFloat.random(in: 2...6))
                                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: isPlaying)
                            }
                        }
                        
                        // Use the once-computed metadataModel from the outer dynamicIsland closure.
                        // compactLeading only needs programTitle while actively playing.
                        Text(metadataModel.programTitle)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactTrailing: {
                Button(intent: LiveActivityTogglePlaybackIntent()) {
                    ZStack {
                        // Use the once-computed narrow control presentation for both the circle
                        // background tint and the play/pause glyph. This is the compact trailing
                        // equivalent of the expanded trailing button.
                        Circle()
                            .fill(controlPres.tint.opacity(0.3))
                            .frame(width: 20, height: 20)
                        
                        Image(systemName: controlPres.systemImage)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(controlPres.tint)
                    }
                }
                .buttonStyle(.plain)
            } minimal: {
                ZStack {
                    // Status background closes over hoisted statusPres; icon choice (play vs radio)
                    // is a pure visual decision driven by isPlaying.
                    Circle()
                        .fill(statusPres.background.opacity(0.3))
                        .frame(width: 18, height: 18)
                    
                    if isPlaying {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "radio")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.gray)
                    }
                }
            }
            .widgetURL(URL(string: "lutheranradio://open"))
        }
    }
}

// MARK: - Lock Screen View

/// Lock screen presentation of the privacy-first Live Activity.
///
/// Rendered by iOS inside the system-provided lock-screen card (constrained height).
/// Consumes narrow presentation values (status, control, metadata) plus one small
/// derived `isPlaying` Boolean, all computed once at the top of `body`.
/// Uses `widgetNowPlayingDisplayModel(...)` + `WidgetMetadataEmphasis` for stable
/// fixed-height title/speaker layout (no conditional row insertion).
///
/// Language switching and playback toggle use the two Live Activity AppIntents.
///
/// - Important: Rendered inside a system card with limited vertical space above
///   the swipe affordance. Use flexible frames, line limits, and modest min-heights
///   to avoid clipping. (Contrast with Dynamic Island regions, which have their own
///   sizing and already use ScrollView for the language alternatives.)
///
/// - Note: Dimensions are intentionally smaller than the corresponding values in
///   `WidgetMetadataLayout` used by the large home widget.
///
/// Snapshot-driven derivation (performed once at the top of `body` — the Live Activity
/// counterpart to pre-deriving onto `SimpleEntry` in the WidgetKit Provider):
/// - `statusPres = makeStatusPresentation()`
/// - `metadataModel = widgetNowPlayingDisplayModel(...)`
/// - `controlPres = makeControlPresentation()` (circle variants chosen locally for weight)
/// - `isPlaying` (small derived Boolean): used only for the label copy decision next to
///   the control button ("Paused" vs "Play"). This label decision is intentionally kept
///   on the semantic flag per the documented division of concerns.
///
/// These narrow values (plus primitives such as `currentLanguage`) are the only data
/// the layout below reads. Direct visualState reads inside the view body are eliminated
/// for presentation concerns.
///
/// - SeeAlso: ``LutheranRadioLiveActivityWidget``, Dynamic Island regions in this file,
///   `WidgetMetadataRegion`, ``widgetNowPlayingDisplayModel``,
///   `SimpleEntry.widgetNowPlayingDisplayModel` (WidgetKit parallel),
///   `LutheranRadioLiveActivityAttributes.ContentState`,
///   `WidgetDisplayModels.swift`, `LutheranRadioWidget.swift`,
///   `PlayerVisualState` (the three mappers),
///   CODING_AGENT.md (Single Source of Truth Principles, Cross-target shared source files,
///   Documentation & Comment Standards, narrow inputs for WidgetKit/ActivityKit),
///   docs/Widget-Presentation-Dataflow.md, <doc:Architecture>, `RadioLiveActivityManager`.
///
/// AGENT NOTE: The shared display model must remain in use for title/speaker stability.
/// Prefer flexible frames + `lineLimit`/`minimumScaleFactor` over tall fixed minHeight.
/// Test lock-screen presentation (not only DI or canvas previews). The language row
/// uses plain buttons and explicit horizontal padding.
struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<LutheranRadioLiveActivityAttributes>
    
    var body: some View {
        // Narrow presentations (status + control + metadata) + small derived `isPlaying`
        // are computed once at the top of `body` (Live Activity equivalent of Provider-level
        // pre-derivation for SimpleEntry). Only narrow values + the hoisted flag are used below.
        // This mirrors the hoisting performed inside the outer `dynamicIsland` closure.
        let currentLanguage = SharedPlayerManager.preferredWidgetLanguage()
        let languageName = SharedPlayerManager.streamForLanguageCode(currentLanguage).language
        let metadataModel = widgetNowPlayingDisplayModel(
            visualState: context.state.visualState,
            streamMetadata: context.state.streamMetadata,
            languageName: languageName
        )
        let statusPres = context.state.visualState.makeStatusPresentation()
        // Compute the narrow control presentation once at the top (mirrors status + metadata
        // pattern). The play/pause button and its tint below read exclusively from this value.
        // Semantic label copy decision also uses a once-computed local for a single read site.
        let controlPres = context.state.visualState.makeControlPresentation()
        // Lock Screen uses circle variants of the control glyphs for visual weight.
        // Derive the exact variant name purely from the narrow control presentation value
        // (no re-inspection of visualState or isActivelyPlaying for glyph choice).
        let lockScreenControlImage = controlPres.systemImage == "pause.fill" ? "pause.circle.fill" : "play.circle.fill"

        // Hoisted once for the semantic label copy ("Paused" vs "Play") that accompanies
        // the control button. This is the documented exception where isActivelyPlaying
        // drives copy rather than glyph choice (see file header and PlayerVisualState).
        // Using a local eliminates a direct context.state.visualState read deep in the tree.
        let isPlaying = context.state.visualState.isActivelyPlaying
        
        VStack(spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "radio")
                    .foregroundStyle(.white)
                    .font(.subheadline)
                
                Text(String(localized: "lutheran_radio_title", table: "Localizable"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                
                Spacer(minLength: 4)
                
                Text("\(getStreamFlag(currentLanguage)) \(getLanguageName(currentLanguage))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            // Status driven from PlayerStatusPresentation (via makeStatusPresentation()).
            Text(statusPres.text)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(statusPres.foreground)
                .lineLimit(1)
            
            // Metadata
            VStack(spacing: 2) {
                Text(metadataModel.programTitle)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                    .opacity(metadataModel.emphasis.opacity)
                    .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 22, alignment: .center)
                
                Text(metadataModel.speakerLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(metadataModel.speakerVisible ? metadataModel.emphasis.opacity : 0)
                    .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 14, alignment: .center)
            }
            
            // Language row + play button (clean, no ScrollView, no pills)
            HStack(spacing: 12) {
                ForEach(getAlternativeStreams(current: currentLanguage), id: \.self) { langCode in
                    Button(intent: LiveActivitySwitchStreamIntent(languageCode: langCode)) {
                        VStack(spacing: 2) {
                            Text(getStreamFlag(langCode))
                                .font(.system(size: 16))
                            Text(getLanguageName(langCode))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
                
                Button(intent: LiveActivityTogglePlaybackIntent()) {
                    VStack(spacing: 2) {
                        // Glyph chosen from the once-computed narrow control presentation (circle variant
                        // selected locally for Lock Screen visual weight). Tint comes directly from the
                        // narrow presentation. No direct visualState.isActivelyPlaying or buttonTintColor
                        // read remains for this control button.
                        Image(systemName: lockScreenControlImage)
                            .font(.title2)
                            .foregroundStyle(controlPres.tint)
                        
                        // Label copy decision kept on the semantic `isPlaying` flag (hoisted above).
                        // This distinguishes "what the button shows" (controlPres) from "what label text
                        // accompanies it" (state-driven copy). Matches prior behavior exactly.
                        // The value is semantically isActivelyPlaying; the hoisting is only for
                        // single-evaluation hygiene (consistent with DI regions).
                        Text(isPlaying
                             ? String(localized: "status_paused", defaultValue: "Paused", table: "Localizable")
                             : String(localized: "Play", defaultValue: "Play", table: "Localizable"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .widgetURL(URL(string: "lutheranradio://open"))
    }
}
