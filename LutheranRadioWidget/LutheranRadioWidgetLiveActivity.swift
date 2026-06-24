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
//   Computed at top of `LockScreenLiveActivityView.body` and inside the outer
//   `dynamicIsland` closure; consumed by regions and status text.
// - Primary control: `makeControlPresentation()` → `PlayerControlPresentation`.
//   Computed once per view/closure and closed over by play/pause buttons.
// - Metadata/emphasis: `widgetNowPlayingDisplayModel(...)` → `WidgetNowPlayingDisplayModel`.
//   Computed once at the top of Lock Screen body and outer Dynamic Island; the narrow
//   model (programTitle, speakerLine, speakerVisible, emphasis) is passed into
//   `.center`, `compactLeading`, and the Lock Screen metadata blocks.
//
// `isActivelyPlaying` (and `buttonTintColor` for non-control radio glyphs) are retained
// only for semantic decisions inside regions (LIVE indicator presence, animation triggers,
// "Local Only" label, decorative tint). Pure play/pause glyph + tint use the narrow control
// presentation (see PlayerVisualState.swift header for the policy).
//
// - SeeAlso: `LutheranRadioLiveActivityAttributes`, `SharedPlayerManager`
//   (PersistedWidgetState, load*/persist*, userRequestedPlay, preferredWidgetLanguage),
//   `PlayerVisualState` (the three mappers), `PlayerStatusPresentation`,
//   `PlayerControlPresentation`, `WidgetNowPlayingDisplayModel`,
//   `widgetNowPlayingDisplayModel(...)`, `WidgetDisplayModels.swift`,
//   `LutheranRadioWidget.swift` (SimpleEntry + Provider snapshot pattern),
//   `RadioLiveActivityManager`,
//   CODING_AGENT.md (Single Source of Truth Principles, Cross-target shared source files,
//   narrow inputs, Documentation & Comment Standards),
//   docs/Widget-Presentation-Dataflow.md,
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

// MARK: - Live Activity Helpers
//
// Status, control, and metadata/emphasis are all obtained from the narrow presentation
// surfaces (`makeStatusPresentation`, `makeControlPresentation`, and
// `widgetNowPlayingDisplayModel`). Call sites derive once at the top of the relevant
// view or outer Dynamic Island closure and close over the narrow values.
//
// `isActivelyPlaying` is used only for semantic / presence decisions (LIVE dot visibility,
// animation bars, "Local Only" vs. bars). Non-control decorative uses of `buttonTintColor`
// (radio glyphs) also remain on the visual state per the documented division of concerns
// in PlayerVisualState.swift.
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
/// AGENT NOTE: Because Live Activity intents execute in the widget extension
/// process, they obtain a fresh view of actor state via the static facades.
/// Treat this surface exactly like other explicit user action surfaces:
/// always go through `userRequestedPlay()` for the "start playing" direction.
/// Direct `play()` calls here would bypass the intent-setting guard and are
/// forbidden.
struct LiveActivityTogglePlaybackIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Toggle Lutheran Radio Playback" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Toggle play/pause from Live Activity.")
    }
    
    func perform() async throws -> some IntentResult {
        #if DEBUG
        print("[LutheranRadioWidgetLiveActivity] LiveActivityTogglePlaybackIntent.perform called")
        #endif
        
        let manager = SharedPlayerManager.shared
        let visualState = await manager.currentVisualState   // Safe actor access (SSOT)
        
        if visualState.isActivelyPlaying {
            await manager.stop()
        } else {
            // Explicit user action from Live Activity (treated as an explicit play surface).
            // Must go through userRequestedPlay() (not raw play()) so that setUserIntentToPlay()
            // and the full guard sequence run. Distinction: internal continuation
            // (post-intent resume in the two canonical switch methods) is the only case
            // allowed to call play() directly.
            await manager.userRequestedPlay()
        }
        
        #if DEBUG
        print("[LutheranRadioWidgetLiveActivity] LiveActivityTogglePlaybackIntent completed – visualState was \(visualState)")
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
        
        let manager = SharedPlayerManager.shared
        
        guard let targetStream = manager.availableStreams.first(where: { $0.languageCode == languageCode }) else {
            #if DEBUG
            print("[LutheranRadioWidgetLiveActivity] LiveActivitySwitchStreamIntent: Language stream not found")
            #endif
            return .result()
        }
        
        await manager.switchToStream(targetStream)
        
        #if DEBUG
        print("[LutheranRadioWidgetLiveActivity] LiveActivitySwitchStreamIntent completed for \(targetStream.language)")
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
            // Derive the three narrow presentations once at the outer Dynamic Island
            // closure level (mirrors Provider pre-derivation for SimpleEntry).
            // Regions close over the already-computed values.
            let controlPres = context.state.visualState.makeControlPresentation()

            let currentLanguageForMetadata = SharedPlayerManager.preferredWidgetLanguage()
            let languageNameForMetadata = SharedPlayerManager.streamForLanguageCode(currentLanguageForMetadata).language
            let metadataModel = widgetNowPlayingDisplayModel(
                visualState: context.state.visualState,
                streamMetadata: context.state.streamMetadata,
                languageName: languageNameForMetadata
            )

            // Explicit return required once the closure body contains statements (let bindings)
            // before the DynamicIsland builder expression. The multi-trailing-closure call
            // no longer qualifies as an implicit-return single-expression closure.
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(context.state.visualState == .playing ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                                .frame(width: 32, height: 32)
                            
                            Image(systemName: "radio")
                                .foregroundColor(context.state.visualState.buttonTintColor.swiftUIColor)
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
                            
                            if context.state.visualState.isActivelyPlaying {
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
                                // Background circle tinting still references the semantic tint surface for
                                // the established visual treatment. The glyph itself now comes from the
                                // outer-derived narrow control presentation.
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
                        
                        if context.state.visualState.isActivelyPlaying {
                            HStack(spacing: 2) {
                                ForEach(0..<3, id: \.self) { index in
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.green)
                                        .frame(width: 2, height: CGFloat.random(in: 4...12))
                                        .animation(.easeInOut(duration: Double.random(in: 0.3...0.7)).repeatForever(autoreverses: true), value: context.state.visualState)
                                }
                            }
                        }
                    }
                }
                
                DynamicIslandExpandedRegion(.center) {
                    // metadataModel and language for it are computed once at the outer dynamicIsland level.
                    let statusPres = context.state.visualState.makeStatusPresentation()
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
                        let statusPres = context.state.visualState.makeStatusPresentation()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(statusPres.background)
                                .frame(width: 6, height: 6)
                            Text(statusPres.text)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        if context.state.visualState.isActivelyPlaying {
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
                                            value: context.state.visualState
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
                // dynamicIsland closure. compactLeading only consumes the already-derived model.
                HStack(spacing: 2) {
                    ZStack {
                        Circle()
                            .fill(context.state.visualState.isActivelyPlaying ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                            .frame(width: 20, height: 20)
                        
                        Image(systemName: "radio")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(context.state.visualState.buttonTintColor.swiftUIColor)
                    }
                    
                    if context.state.visualState.isActivelyPlaying {
                        HStack(spacing: 1) {
                            ForEach(0..<2, id: \.self) { index in
                                RoundedRectangle(cornerRadius: 0.5)
                                    .fill(Color.green)
                                    .frame(width: 1, height: CGFloat.random(in: 2...6))
                                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: context.state.visualState)
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
                    let statusPres = context.state.visualState.makeStatusPresentation()
                    Circle()
                        .fill(statusPres.background.opacity(0.3))
                        .frame(width: 18, height: 18)
                    
                    if context.state.visualState.isActivelyPlaying {
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
/// Consumes three narrow presentation values derived once at the top of `body`:
/// `statusPres`, `metadataModel` (WidgetNowPlayingDisplayModel), and `controlPres`.
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
///
/// These three narrow values (plus primitives such as `currentLanguage`) are the only
/// data the layout below reads.
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
        // All three narrow presentations are derived once at the top of `body`
        // (the Live Activity equivalent of Provider-level pre-derivation for SimpleEntry).
        // Only the narrow values (plus language primitives) are used below.
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
        // Semantic uses of isActivelyPlaying (for label copy) are left in place; only the
        // glyph + tint decision for the control moves to the narrow type.
        let controlPres = context.state.visualState.makeControlPresentation()
        // Lock Screen uses circle variants of the control glyphs for visual weight.
        // Derive the exact variant name purely from the narrow control presentation value
        // (no re-inspection of visualState or isActivelyPlaying for glyph choice).
        let lockScreenControlImage = controlPres.systemImage == "pause.fill" ? "pause.circle.fill" : "play.circle.fill"
        
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
                        
                        // Label copy decision kept on the semantic isActivelyPlaying flag (not presentation).
                        // This distinguishes "what the button shows" (controlPres) from "what label text
                        // accompanies it" (state-driven copy). Matches prior behavior exactly.
                        Text(context.state.visualState.isActivelyPlaying
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
