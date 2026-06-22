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
// - SeeAlso: `LutheranRadioLiveActivityAttributes`, `SharedPlayerManager`
//   (PersistedWidgetState, load*/persist*, userRequestedPlay, preferredWidgetLanguage),
//   `PlayerVisualState`, `WidgetDisplayModels`, `RadioLiveActivityManager`,
//   CODING_AGENT.md (Single Source of Truth Principles + "Cross-target shared
//   source files (non-Core)"), <doc:Architecture>, README.md.
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
// These thin wrappers + status resolvers provide the Live Activity (both DI and
// Lock Screen) with consistent presentation derived from the shared display models
// and the authoritative snapshot. All helpers are private to this file.

/// Maps `PlayerVisualState` to the indicator dot color used in Live Activity chrome.
///
/// Used in both the bottom status row (Dynamic Island) and the minimal/leading
/// regions. Colors are deliberately high-level (green/orange/red/gray) rather
/// than the exact `backgroundColor` values from the enum so the LA can remain
/// legible inside the system-provided card / Dynamic Island surfaces.
private func getStatusColor(_ visualState: PlayerVisualState) -> Color {
    switch visualState {
    case .thermalPaused: return .orange
    case .securityLocked: return .red
    case .playing:       return .green
    case .prePlay, .cleared, .userPaused: return .gray
    }
}

/// Derives the localized primary status string shown in Live Activity.
///
/// Replaces any legacy `streamStatus`. Sources `hasError` from `loadSharedState()`
/// (which itself prefers the `PersistedWidgetState` snapshot) to stay in parity
/// with the home widget timeline providers. The string is one of:
/// - "Connection error"
/// - localized "status_thermal_paused"
/// - "LIVE"
/// - "Ready"
///
/// - Note: All strings use the "Localizable" table via `String(localized:...)`.
/// - SeeAlso: ``loadSharedState()`` in SharedPlayerManager, `getCurrentStreamStatus`
///   usage sites below, WidgetDisplayModels.
private func getCurrentStreamStatus(visualState: PlayerVisualState) -> String {
    let hasError = SharedPlayerManager.shared.loadSharedState().hasError
    if hasError {
        return String(localized: "Connection error", defaultValue: "Connection error", table: "Localizable")
    } else if visualState == .thermalPaused {
        return String(localized: "status_thermal_paused", defaultValue: "Thermal pause", table: "Localizable")
    } else if visualState.isActivelyPlaying {
        return String(localized: "LIVE", defaultValue: "Live", table: "Localizable")
    } else {
        return String(localized: "Ready", defaultValue: "Ready", table: "Localizable")
    }
}

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
// (WidgetMetadataEmphasis + widgetNowPlayingDisplayModel). Live Activity only
// computes the `languageName` for the fallback and passes the resolved model
// into the fixed metadata region used by both DI expanded center and Lock Screen.

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
/// Registers an `ActivityConfiguration` that supplies:
/// - Lock Screen presentation via `LockScreenLiveActivityView`
/// - Dynamic Island presentations (expanded, compactLeading, compactTrailing, minimal)
///
/// The `ContentState` (`visualState` + `streamMetadata`) is pushed by
/// `RadioLiveActivityManager` using snapshots from `SharedPlayerManager`.
/// All language resolution, metadata display models, and status strings are
/// derived via the documented SSOT helpers so that the Live Activity stays
/// consistent with home widgets.
///
/// - Important: The widget kind `"LutheranRadioLiveActivity"` must match the
///   kind used when starting/ending activities in `RadioLiveActivityManager`.
/// - SeeAlso: `LutheranRadioLiveActivityAttributes`,
///   `LockScreenLiveActivityView`, `RadioLiveActivityManager`,
///   CODING_AGENT.md (Cross-target shared source files).
struct LutheranRadioLiveActivityWidget: Widget {
    let kind: String = "LutheranRadioLiveActivity"

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LutheranRadioLiveActivityAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
                .widgetURL(URL(string: "lutheranradio://open"))
        } dynamicIsland: { context in
            DynamicIsland {
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
                                Circle()
                                    .fill(context.state.visualState.buttonTintColor.swiftUIColor.opacity(0.2))
                                    .frame(width: 44, height: 44)
                                
                                Image(systemName: context.state.visualState.isActivelyPlaying ? "pause.fill" : "play.fill")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .foregroundColor(context.state.visualState.buttonTintColor.swiftUIColor)
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
                    let currentLanguage = SharedPlayerManager.preferredWidgetLanguage()
                    // Use the shared display model so the title is always present and the speaker line
                    // reserves vertical space (via \u{00A0} + opacity) for layout stability.
                    let languageName = SharedPlayerManager.streamForLanguageCode(currentLanguage).language
                    let metadataModel = widgetNowPlayingDisplayModel(
                        visualState: context.state.visualState,
                        streamMetadata: context.state.streamMetadata,
                        languageName: languageName
                    )
                    VStack(spacing: 6) {
                        VStack(spacing: 2) {
                            Text(getCurrentStreamStatus(visualState: context.state.visualState))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(context.state.visualState.textColor.swiftUIColor)
                            
                            // Fixed metadata region (no conditional insertion) using shared model + emphasis.
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
                        HStack(spacing: 4) {
                            Circle()
                                .fill(getStatusColor(context.state.visualState))
                                .frame(width: 6, height: 6)
                            Text(getCurrentStreamStatus(visualState: context.state.visualState))
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
                let currentLanguage = SharedPlayerManager.preferredWidgetLanguage()
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
                        
                        // Use shared model for title (compact leading shows only while actively; model yields metadata or live fallback).
                        let languageName = SharedPlayerManager.streamForLanguageCode(currentLanguage).language
                        let compactModel = widgetNowPlayingDisplayModel(
                            visualState: context.state.visualState,
                            streamMetadata: context.state.streamMetadata,
                            languageName: languageName
                        )
                        Text(compactModel.programTitle)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactTrailing: {
                Button(intent: LiveActivityTogglePlaybackIntent()) {
                    ZStack {
                        Circle()
                            .fill(context.state.visualState.buttonTintColor.swiftUIColor.opacity(0.3))
                            .frame(width: 20, height: 20)
                        
                        Image(systemName: context.state.visualState.isActivelyPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(context.state.visualState.buttonTintColor.swiftUIColor)
                    }
                }
                .buttonStyle(.plain)
            } minimal: {
                ZStack {
                    Circle()
                        .fill(getStatusColor(context.state.visualState).opacity(0.3))
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
/// Rendered by iOS inside the system lock-screen card (constrained height).
/// Uses the shared `widgetNowPlayingDisplayModel(...)` + `WidgetMetadataEmphasis`
/// (from WidgetDisplayModels) for stable title/speaker layout without conditional
/// row insertion. Language switching and playback toggle are provided by the
/// two Live Activity intents.
///
/// - Important: This view is rendered by iOS inside a system-provided rounded card
///   on the lock screen. The system allocates a constrained vertical content area
///   (above the "Avaa pyyhkäisemällä ylös" / swipe affordance). Fixed min-heights,
///   generous spacing, and a tall monolithic VStack will cause bottom clipping and
///   visual crowding against the card edges.
///
///   Dynamic Island uses separate region builders with their own sizing and already
///   uses tighter frames + ScrollView for alternatives; this is why DI is less
///   affected or unaffected by the same content.
///
/// - Note: All vertical dimensions here are deliberately smaller than the
///   corresponding large home widget values in `WidgetMetadataLayout`. The lock
///   screen card has less usable height than a systemLarge widget.
///
/// - SeeAlso: ``LutheranRadioLiveActivityWidget``, the DynamicIsland regions in
///   this file, `WidgetMetadataRegion` (contrast), ``widgetNowPlayingDisplayModel``,
///   `LutheranRadioLiveActivityAttributes.ContentState`,
///   CODING_AGENT.md (Single Source of Truth Principles + Cross-target shared
///   source files), <doc:Architecture>, `RadioLiveActivityManager`.
///
/// AGENT NOTE: When editing, prefer flexible frames + lineLimit/minimumScaleFactor
/// over tall minHeight. Always test on lock screen presentation (not just DI or
/// previews). The language row uses plain buttons (no ScrollView here) and
/// receives explicit `.padding(.horizontal, 8)`. The shared display model must
/// remain in use for title/speaker stability and emphasis.
struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<LutheranRadioLiveActivityAttributes>
    
    var body: some View {
        let currentLanguage = SharedPlayerManager.preferredWidgetLanguage()
        let languageName = SharedPlayerManager.streamForLanguageCode(currentLanguage).language
        let metadataModel = widgetNowPlayingDisplayModel(
            visualState: context.state.visualState,
            streamMetadata: context.state.streamMetadata,
            languageName: languageName
        )
        
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
            
            // Status
            Text(getCurrentStreamStatus(visualState: context.state.visualState))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(context.state.visualState.textColor.swiftUIColor)
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
                        Image(systemName: context.state.visualState.isActivelyPlaying
                              ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(context.state.visualState.buttonTintColor.swiftUIColor)
                        
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
