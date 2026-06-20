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
//  or having to know about SharedPlayerManager actor hops.
//
//  Previews:
//  Use `PlayerViewModel.makeMock(...)` to obtain an isolated instance for #Preview and tests.
//  No side effects or actor access from the mock path.
//
//  - Important: Do not duplicate resurrection rules, intent logic, or security decisions here.
//  - SeeAlso: RadioPlayerCoordinator (the driver), SharedPlayerManager (SSOT via push),
//    PlayerVisualState.swift, StreamProgramMetadata.swift,
//    CODING_AGENT.md (Single Source of Truth Principles + Cross-target shared files),
//    <doc:Architecture>.
//
//  Created by Jari Lammi on 19.6.2026.
//

import Foundation
import Observation

/// Observable presentation model for the player screen.
///
/// All properties are mutated on the @MainActor by the RadioPlayerCoordinator (or test/preview code).
/// SwiftUI views observe them directly via the Observation framework (no @Published needed).
///
/// Thread-safety: @MainActor isolation + coordinator is the only writer in production.
///
/// Sleep timer surface:
/// - `sleepTimerRemaining` is pushed by coordinator (via `syncSleepTimerToViewModel`).
/// - `selectSleepTimer(minutes:)` and `cancelSleepTimer()` forward to coordinator-owned logic
///   (the SwiftUI dialog in PlaybackControlsView is the caller). This keeps set/cancel, countdown
///   glue, and state sync in the single source of truth (coordinator + SharedPlayerManager).
@Observable
@MainActor
final class PlayerViewModel {

    // MARK: - Core observable state (as specified)

    /// Current visual appearance / status of playback (drives colors, labels, play/pause glyph).
    var visualState: PlayerVisualState = .prePlay

    /// Index into `DirectStreamingPlayer.availableStreams` that the UI believes is selected.
    /// Kept in sync by the coordinator (owner of selection math + needle).
    var selectedStreamIndex: Int = 0

    /// Parsed program / speaker metadata from the active ICY stream (if any).
    var currentMetadata: StreamProgramMetadata?

    /// Remaining sleep timer duration in seconds. Nil when no timer is active.
    /// Updated by the coordinator's local countdown (beginLocalSleepTimerDisplay / Task)
    /// which also drives sync + icon state in PlaybackControlsView.
    /// The SwiftUI confirmationDialog reads this to decide whether to show the Cancel action.
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
    func play() {
        onPlayRequested?()
    }

    /// Request pause/stop. Forwards to the injected closure.
    func pause() {
        onPauseRequested?()
    }

    /// Select a stream/language by index in the canonical availableStreams array.
    /// Forwards to the injected closure (coordinator performs optimistic UI + timing).
    func selectLanguage(at index: Int) {
        onLanguageSelected?(index)
    }

    /// Request a sleep timer preset (e.g. 15, 30, 45 or 60 minutes).
    /// Forwards to the injected closure so coordinator retains ownership of setSleepTimer,
    /// isSleepTimerInteractionActive, background deferral, beginLocalSleepTimerDisplay,
    /// and syncSleepTimerToViewModel.
    func selectSleepTimer(minutes: Int) {
        onSleepTimerPresetSelected?(minutes)
    }

    /// Request cancellation of the current sleep timer (if any).
    /// Forwards to the injected closure; coordinator owns cancel + display stop + notification paths.
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
}

// MARK: - Preview / Test Support

extension PlayerViewModel {

    /// Creates a fully populated mock instance for SwiftUI `#Preview` and unit tests.
    ///
    /// - No actor access or side effects occur.
    /// - Action closures are wired to simple prints so you can exercise buttons in the canvas.
    /// - All 21 languages and all visual states are valid; the mock does not enforce stream count.
    ///
    /// Example:
    /// ```swift
    /// #Preview {
    ///     let vm = PlayerViewModel.makeMock(visualState: .playing)
    ///     PlayerMainPreview(viewModel: vm)
    /// }
    /// ```
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
// This struct exists so that we can immediately provide a working #Preview for the VM
// without depending on the legacy UIKit components being converted yet.
// It demonstrates how a future pure-SwiftUI RadioPlayerView would consume the model.

#if DEBUG
import SwiftUI

/// Lightweight SwiftUI preview surface that exercises the observable PlayerViewModel.
/// Used both for standalone preview of the VM and as a template for a future main view.
struct PlayerMainPreview: View {
    @State var viewModel: PlayerViewModel

    var body: some View {
        VStack(spacing: 24) {
            // Title area
            Text("Lutheran Radio")
                .font(.largeTitle.weight(.semibold))

            // Status pill (mimics PlaybackControlsView status)
            Text(statusText)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(uiColor: viewModel.visualState.backgroundColor))
                .foregroundStyle(Color(uiColor: viewModel.visualState.textColor))
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
        .onChange(of: viewModel.visualState) { _, new in
            if new == .securityLocked && !viewModel.isShowingSecurityError {
                viewModel.isShowingSecurityError = true
            }
        }
    }

    private var statusText: String {
        switch viewModel.visualState {
        case .playing:      return "Playing"
        case .prePlay:      return "Connecting"
        case .userPaused:   return "Paused"
        case .thermalPaused: return "Thermal Paused"
        case .securityLocked: return "Security Failed"
        }
    }

    private func flagEmoji(for index: Int) -> String {
        // Approximate mapping for preview (real app uses actual flag assets + DirectStreamingPlayer data)
        let codes = ["🇩🇰", "🇩🇪", "🇬🇧", "🇪🇪", "🇫🇮"]
        return codes[safe: index] ?? "🏳️"
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
