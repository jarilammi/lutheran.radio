//
//  DirectStreamingPlayer+StatusCallbackDelivery.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Engine-owned status and metadata callback delivery: MainActor-safe status hops,
//  transient KVO / connect-buffer suppress gates, last-value dedup, and optional
//  widget-persist side effects. Keeps the delegate → UI → widget pipeline out of
//  the primary façade body while preserving every UITestMode and sticky-pause guard.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public engine façade; this file owns one domain.
//
//  Ownership (do not invert):
//  - This domain owns **status callback delivery** (``safeOnStatusChange``,
//    ``deliverStatusChange``, ``invokeStatusCallbacks``), **transient suppress
//    gates** (``shouldSuppressTransientKVOStatus``,
//    ``shouldSkipWidgetSaveForTransientConnectOrBuffer``), and **metadata
//    callback delivery** (``safeOnMetadataChange``).
//  - Stored callbacks / dedup / init-queue state remain on the façade class body
//    (`onStatusChange`, `onMetadataChange`, `delegate`, `isInitializing`,
//    `pendingStatusChanges`, `lastEmittedStatus` — extensions cannot declare
//    stored properties).
//  - Visual / intent SSOT and widget snapshot writes remain ``SharedPlayerManager``;
//    this domain only *invokes* ``saveCurrentState()`` / ``updateNowPlayingInfo()``
//    after a real status emission (never owns PlayerVisualState).
//  - Delegate setter (``setDelegate``) stays on the façade next to the stored
//    ``delegate`` property; this domain only *calls* the delegate.
//  - Status *producers* (observers, recovery, network path, play/stop, attach)
//    remain in their own domain files and call ``safeOnStatusChange`` only.
//
//  Process invariants:
//  - UITestMode / ``isTesting`` hard-returns from ``safeOnStatusChange`` so no
//    status feeds the widget / Live Activity / Now Playing pipeline under tests.
//  - Transient KVO `status_stopped` / `status_buffering` while visual SSOT is
//    actively playing suppresses the full pipeline and re-asserts Now Playing rate.
//  - Init-time statuses queue on ``pendingStatusChanges`` until ``isInitializing``
//    clears; flush path on the façade init uses ``invokeStatusCallbacks`` directly.
//  - Last-value dedup on ``lastEmittedStatus`` prevents identical consecutive
//    tuples from re-driving the entire pipeline (KVO jitter).
//  - Localization: localized string is computed once for UI/logs; the delegate
//    receives the raw Localizable key (ViewController contract).
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is
//  file-scoped). Prefer this domain over re-implementing status hops or suppress
//  gates in observers/recovery. Do not mix play/stop surgery, deinit hygiene, or
//  periodic certificate validation scheduling into this domain.
//
//  - SeeAlso: DirectStreamingPlayer.swift (isolation map, stored callback state),
//    DirectStreamingPlayer+Observers.swift, DirectStreamingPlayer+PlaybackControl.swift,
//    DirectStreamingPlayer+PlayerItemRecovery.swift, DirectStreamingPlayer+NetworkPath.swift,
//    DirectStreamingPlayer+DeinitHygiene.swift (``clearCallbacks()``),
//    SharedPlayerManager.saveCurrentState(), SharedPlayerManager.updateNowPlayingInfo(),
//    SharedPlayerManager.isRunningInUITestMode, CODING_AGENT.md (test isolation + SSOT).
//

import Foundation

// MARK: - Status / metadata callback delivery

extension DirectStreamingPlayer {

    /// AVPlayer KVO (`timeControlStatus`, buffer empty, etc.) can emit `status_stopped` /
    /// `status_buffering` for sub-second ICY/Fig glitches while `PlayerVisualState` is still `.playing`.
    /// Suppresses the full delegate → UI → widget pipeline and re-asserts Now Playing playback rate
    /// so Control Center / lock screen do not flash an extra pause.
    @MainActor
    func shouldSuppressTransientKVOStatus(isPlaying: Bool, reasonKey: String?) async -> Bool {
        guard !isPlaying, let reasonKey else { return false }
        switch reasonKey {
        case "status_stopped", "status_buffering":
            break
        default:
            return false
        }
        return await SharedPlayerManager.shared.currentVisualState.isActivelyPlaying
    }

    /// Returns true when a stable connect/buffer status should not trigger widget persistence:
    /// `isPlaying` is false but `currentVisualState` is already `.prePlay` or `.playing`.
    @MainActor
    func shouldSkipWidgetSaveForTransientConnectOrBuffer(
        isPlaying: Bool,
        reasonKey: String?
    ) async -> Bool {
        guard !isPlaying, let reasonKey else { return false }
        switch reasonKey {
        case "status_connecting", "status_buffering":
            break
        default:
            return false
        }
        let visual = await SharedPlayerManager.shared.currentVisualState
        return visual == .prePlay || visual == .playing
    }

    @MainActor
    func deliverStatusChange(isPlaying: Bool, reasonKey: String?) {
        let didEmit = invokeStatusCallbacks(isPlaying: isPlaying, reasonKey: reasonKey)

        // Uses exact keys from Localizable.xcstrings. Only force a widget save on real emissions.
        if didEmit {
            let isStableState = isPlaying ||
            reasonKey == "status_playing" ||
            reasonKey == "status_paused" ||
            reasonKey == "status_stopped" ||
            reasonKey == "status_paused_call" ||
            reasonKey == "status_thermal_paused" ||
            reasonKey == "status_no_internet" ||
            reasonKey == "status_security_failed" ||
            reasonKey == "status_stream_unavailable" ||
            reasonKey == "status_connecting" ||
            reasonKey == "status_ssl_transition" ||
            reasonKey == "status_buffering" ||
            reasonKey == "status_failed"

            if isStableState {
                Task {
                    if await self.shouldSkipWidgetSaveForTransientConnectOrBuffer(
                        isPlaying: isPlaying,
                        reasonKey: reasonKey
                    ) {
                        #if DEBUG
                        print("[DirectStreamingPlayer] safeOnStatusChange: transient \(reasonKey ?? "nil") — skipping widget save (visual SSOT prePlay/playing)")
                        #endif
                        return
                    }
                    let vis = await SharedPlayerManager.shared.currentVisualState
                    if vis.mustSuppressResurrection {
                        #if DEBUG
                        print("[DirectStreamingPlayer] safeOnStatusChange: stable stopped (isPlaying=\(isPlaying), key='\(reasonKey ?? "nil")') while sticky pause — skipping force save (explicit stop path already persisted correct visual+lang)")
                        #endif
                    } else {
                        #if DEBUG
                        print("[DirectStreamingPlayer] safeOnStatusChange: STABLE final state (isPlaying=\(isPlaying), key='\(reasonKey ?? "nil")') → forcing widget save")
                        #endif
                        await SharedPlayerManager.shared.saveCurrentState()
                    }
                }
            } else {
                #if DEBUG
                print("[DirectStreamingPlayer] safeOnStatusChange: transient state (isPlaying=\(isPlaying), key='\(reasonKey ?? "nil")') → skipping widget save")
                #endif
            }
        }
    }

    /// Thread-safe entry for status producers (KVO, recovery, path, play/stop, attach).
    ///
    /// Hops to the main queue, optionally queues during ``isInitializing``, applies
    /// transient KVO suppress, then ``deliverStatusChange``. Hard no-op under UITestMode.
    ///
    /// - Parameters:
    ///   - isPlaying: Engine audible / intended-playing flag for this status.
    ///   - reasonKey: Exact Localizable key (e.g. `"status_playing"`); delegate receives the key.
    /// - SeeAlso: ``deliverStatusChange(isPlaying:reasonKey:)``, ``invokeStatusCallbacks(isPlaying:reasonKey:)``,
    ///   ``shouldSuppressTransientKVOStatus(isPlaying:reasonKey:)``,
    ///   ``SharedPlayerManager/isRunningInUITestMode``
    func safeOnStatusChange(isPlaying: Bool, reasonKey: String?) {
        // SAFETY: Never feed status into the delegate → UI → widget / Live Activity / Now Playing pipeline
        // when running under UI test mode. This is the root cause of:
        //   • audible radio stream before tests execute
        //   • WidgetRenderer_Activities 0x8BADF00D watchdog crash (Chrono renderer woken at launch)
        //
        // Why both checks:
        //   • `isTesting` delegates to SharedPlayerManager.isRunningInUITestMode (the SSOT)
        //   • Direct check on the SSOT is defense-in-depth in case isTesting is read before
        //     the first access or during early static/coordinator construction.
        // The SSOT itself prefers the explicit "-UITestMode" launch argument.
        //
        // See: SharedPlayerManager.isRunningInUITestMode, ViewController cold-launch guard,
        // CODING_AGENT.md (test isolation requirements).
        if isTesting || SharedPlayerManager.isRunningInUITestMode {
            return
        }

        DispatchQueue.main.async {
            if self.isInitializing {
                self.pendingStatusChanges.append((isPlaying, reasonKey))
            } else {
                Task { @MainActor in
                    if await self.shouldSuppressTransientKVOStatus(isPlaying: isPlaying, reasonKey: reasonKey) {
                        #if DEBUG
                        print("[DirectStreamingPlayer] safeOnStatusChange: transient \(reasonKey ?? "nil") while visualState .playing → suppress pipeline")
                        #endif
                        #if LUTHERAN_MAIN_APP
                        await SharedPlayerManager.shared.updateNowPlayingInfo()
                        #endif
                        return
                    }
                    self.deliverStatusChange(isPlaying: isPlaying, reasonKey: reasonKey)
                }
            }
        }
    }

    /// Returns true if the status was actually emitted (not a duplicate).
    ///
    /// - Parameters:
    ///   - isPlaying: Engine audible / intended-playing flag for this status.
    ///   - reasonKey: Exact Localizable key; delegate receives the key (not localized text).
    /// - Returns: `true` when callbacks ran; `false` when last-value dedup suppressed a duplicate.
    /// - SeeAlso: ``safeOnStatusChange(isPlaying:reasonKey:)``, ``lastEmittedStatus``
    @discardableResult
    func invokeStatusCallbacks(isPlaying: Bool, reasonKey: String?) -> Bool {
        // Simple last-value dedup: identical consecutive tuples are a no-op.
        // This prevents KVO jitter and duplicate callback storms from re-driving
        // the entire delegate → UI → widget pipeline.
        let incoming = (isPlaying, reasonKey)
        if lastEmittedStatus?.isPlaying == isPlaying && lastEmittedStatus?.reasonKey == reasonKey {
            return false
        }
        lastEmittedStatus = incoming

        // Compute localized string once for UI / logs / delegate (backward compatible)
        let localizedStatus = reasonKey.map { String(localized: String.LocalizationValue($0), table: "Localizable") } ?? ""

        onStatusChange?(isPlaying, localizedStatus)

        // Pass the raw key to the delegate (ViewController expects the key, not the translated text)
        delegate?.onStatusChange(isPlaying ? .playing : .stopped, reasonKey: reasonKey)

        #if DEBUG
        print("[DirectStreamingPlayer] invokeStatusCallbacks → isPlaying=\(isPlaying), reasonKey='\(reasonKey ?? "nil")', localized='\(localizedStatus)'")
        #endif
        return true
    }

    /// Delivers ICY / stream title metadata to SharedPlayerManager and the optional metadata closure.
    ///
    /// - Parameter metadata: Stream title text, or `nil` to clear.
    /// - SeeAlso: DirectStreamingPlayer+Metadata.swift, ``onMetadataChange``
    func safeOnMetadataChange(metadata: String?) {
        #if LUTHERAN_MAIN_APP
        Task {
            await SharedPlayerManager.shared.didUpdateStreamMetadata(metadata)
        }
        #endif
        Task { @MainActor [weak self] in
            self?.onMetadataChange?(metadata)
        }
    }
}
