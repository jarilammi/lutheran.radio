//
//  DirectStreamingPlayer+AudioSession.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 25.7.2026.
//
//  Engine-owned AVAudioSession category configuration, activation, and deactivation.
//  Single owner for playback session setCategory + setActive paths used by cold launch,
//  stream switches, attach, host reconfigure, and tuning-clip preparation.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public engine façade; this file owns one domain.
//
//  Ownership (do not invert):
//  - This domain owns **category + activate/deactivate** for the shared `.playback` session
//    (``configureAudioSessionAsync()``, ``setupAudioSession()``, ``deactivateAudioSessionAsync()``).
//  - Interruption / route *observers* live in `+AudioSessionInterruption.swift` (separate domain).
//  - Local file-clip construction lives in `+LocalClipPlayer.swift`; it calls
//    ``configureAudioSessionAsync()`` and never `setActive` on MainActor.
//  - Host may re-enter via `ViewController.reconfigureAudioSession()` → configure only.
//  - Stored `audioSession` injection and interruption flags live on the façade class body
//    (extensions cannot declare stored state).
//
//  Security / process invariants:
//  - No-op under UITestMode (`isTesting` / `SharedPlayerManager.isRunningInUITestMode`).
//  - No-op in widget/extension (`.appex` path) — primary protection is membership exclusion;
//    path guard is defense-in-depth.
//  - Never call `setCategory` / `setActive` outside this domain.
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is
//  file-scoped). Prefer this domain file over re-implementing session activation in call sites.
//  Dynamic IMP dispatch for iOS 27 async activate/deactivate must remain dual-Xcode-26/27 compatible.
//
//  - SeeAlso: DirectStreamingPlayer.swift, DirectStreamingPlayer+AudioSessionInterruption.swift,
//    DirectStreamingPlayer+LocalClipPlayer.swift, ViewController.reconfigureAudioSession,
//    TuningSoundCoordinator, CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
@unsafe @preconcurrency import AVFoundation

// MARK: - Audio session configure / activate / deactivate

extension DirectStreamingPlayer {

    /// Reusable @MainActor async helper for AVAudioSession configuration.
    ///
    /// This is the **single source of truth** for audio session category configuration
    /// and activation (and the planned deactivation surface).
    ///
    /// - Sets the `.playback` category (via the synchronous `setCategory`) **only** when
    ///   it is not already `.playback`. This follows Apple guidance for the initial
    ///   configuration while avoiding "called on the main thread while the audio session
    ///   is active" warnings from SessionCore during re-entrancy (route changes,
    ///   interruptions, stream switches, tuning sound setup, etc.).
    /// - On iOS 27.0 and later: activates via the non-blocking
    ///   `activateWithOptions:completionHandler:` (the async spelling) using a dynamic
    ///   runtime dispatch (see ``activateAsyncDynamic(session:wasAlreadyPlayback:)``).
    /// - On iOS 26.2 (deployment target): the activation is performed on a background
    ///   queue via `DispatchQueue.global` + continuation. This ensures the actual
    ///   `setActive` call is never executed while the main thread is blocked, eliminating
    ///   the runtime warning:
    ///   "This method can lead to UI unresponsiveness if called on the main thread.
    ///    Consider using the asynchronous activate/deactivate API instead."
    ///
    /// All audio activation paths (init setup, `play()`, `startPlayback`, stream switches,
    /// tuning sound, interruption recovery, route changes, category changes) must flow through
    /// this method, the thin `setupAudioSession()` wrapper, or (from ViewController) via
    /// `reconfigureAudioSession()`.
    ///
    /// Call sites are already structured as `Task { @MainActor in await ... }` or direct
    /// `await` from @MainActor contexts. The main thread remains responsive during activation.
    ///
    /// **Xcode / SDK compatibility (important for contributors):**
    /// This file is required to compile on both the minimum supported Xcode (26) and
    /// newer Xcode versions. The dynamic IMP dispatch is used so that a direct reference
    /// to the iOS 27 API never appears in source when built against the Xcode 26 SDK.
    /// When built with Xcode 27+, the `#available(iOS 27.0, *)` branch executes, but we
    /// deliberately continue using the runtime lookup instead of the typed API. This
    /// preserves the ability for the same source to build on Xcode 26.
    ///
    /// Runtime behavior:
    /// - On iOS 27.0+: real asynchronous activation via the framework completion handler.
    /// - On iOS 26.x: synchronous `setActive` is executed off the main thread (no main-thread warning).
    ///
    /// Short local file clips (`AVAudioPlayer`) must **not** call `prepareToPlay` / `play`
    /// on the main actor after this returns — those APIs can implicitly re-activate the
    /// session on the calling thread. Use ``startLocalClipPlayer(contentsOf:volume:numberOfLoops:)``
    /// for bundled tuning sounds so construction and start stay off the main actor.
    ///
    /// - Returns: `true` on successful category + activate; `false` on error or under `isTesting`.
    ///
    /// - Precondition: Must be called from a `@MainActor` context.
    /// - Important: Never call `setCategory` or `setActive` directly outside this helper.
    ///   Never replace the dynamic dispatch with a direct `activate(options:completionHandler:)`
    ///   call unless the minimum supported Xcode version is raised above 26.
    /// - Note: Respects `isTesting` (SSOT via `SharedPlayerManager.isRunningInUITestMode`) exactly.
    ///   Under test mode this is a no-op (returns `false`).
    /// - SeeAlso: ``setupAudioSession()``, ``deactivateAudioSessionAsync()``,
    ///   ``startLocalClipPlayer(contentsOf:volume:numberOfLoops:)``,
    ///   `ViewController.reconfigureAudioSession()`,
    ///   `ViewController.handleInterruption(_:)`, `ViewController.handleRouteChange(_:)`,
    ///   CODING_AGENT.md (AV session + documentation rules).
    @MainActor
    func configureAudioSessionAsync() async -> Bool {
        // Widget / extension safety (lightweight no-op path).
        // Primary protection: this file is excluded from LutheranRadioWidgetExtension target
        // via membershipExceptions (see project.pbxproj and CODING_AGENT.md cross-target rules).
        // If the file is ever accidentally compiled for an extension, this guard + the
        // early returns in init paths prevent AVAudioSession configuration in the wrong process.
        if Bundle.main.bundleURL.pathExtension == "appex" {
            return false
        }

        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] Skipped audio session setup for tests...")
            #endif
            return false
        }
        
        let session = audioSession
        let wasAlreadyPlayback = session.category == .playback
        
        do {
            if !wasAlreadyPlayback {
                // Conditional to avoid SessionCore "while audio session is active" warnings
                // when reconfiguring an already-active playback session.
                try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            }
            
            let activated: Bool
            if #available(iOS 27.0, *) {
                // iOS 27.0+: use the non-blocking async activation path.
                // We always resolve via dynamic dispatch (selector + IMP) rather than the
                // typed API. This is required so the identical source compiles on Xcode 26
                // (where the declaration does not exist in the SDK).
                // See the availability and compatibility notes on `configureAudioSessionAsync`.
                activated = await Self.activateAsyncDynamic(session: session, wasAlreadyPlayback: wasAlreadyPlayback)
            } else {
                // iOS 26.2 deployment fallback:
                // Perform setActive off the main thread. This eliminates the AVAudioSession
                // runtime diagnostic that is emitted when the synchronous API is invoked
                // directly from a main-thread / @MainActor context.
                activated = await Self.activateSynchronouslyOffMainThread(session: session)
            }
            return activated
        } catch {
            #if DEBUG
            print("[DirectStreamingPlayer] Failed to configure audio session: \(error.localizedDescription)")
            #endif
            return false
        }
    }

    /// Dynamic dispatch for `activateWithOptions:completionHandler:` using the raw IMP.
    ///
    /// This wrapper lets the project compile from a single source on both the minimum
    /// supported Xcode (26, against the iOS 26 SDK) *and* Xcode 27+ (against the iOS 27 SDK).
    ///
    /// - When built with Xcode 26 the iOS 27 API symbol does not exist, so any direct
    ///   call would fail to compile.
    /// - When built with Xcode 27+ the API is visible, but we intentionally keep using
    ///   the runtime `NSSelectorFromString` + `method(for:)` + `unsafeBitCast` path.
    ///   This guarantees the source remains buildable on Xcode 26 without `#if` / compiler
    ///   version conditionals.
    ///
    /// At runtime on iOS 27.0+, `responds(to:)` succeeds and the real asynchronous
    /// implementation is invoked.
    ///
    /// We use `method(for:)` + `unsafeBitCast` to the precise `@convention(c)` signature because
    /// the method takes a scalar `NSUInteger` (AVAudioSessionActivationOptions) as the first
    /// argument after SEL, followed by a block. The NSObject `perform(_:with:with:)` API always
    /// passes `id` arguments and has the wrong ABI, which produced crashes inside the handler
    /// closure on Xcode 27 beta + iOS 27 simulator.
    @available(iOS 27.0, *)
    private static func activateAsyncDynamic(session: AVAudioSession, wasAlreadyPlayback: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let selector = NSSelectorFromString("activateWithOptions:completionHandler:")

            guard session.responds(to: selector),
                  let imp = unsafe session.method(for: selector) else {
                continuation.resume(returning: false)
                return
            }

            // SAFETY: unsafeBitCast of the IMP is required to obtain a callable function pointer
            // with the exact C ABI of the ObjC method (scalar UInt options + escaping block).
            //
            // This is the only technique that lets us invoke the iOS 27+ async activation API
            // while keeping the identical source compilable on both Xcode 26 (where the
            // declaration is absent from the SDK) and Xcode 27+. The cast is isolated to this
            // helper; the completion block is invoked exactly once by the framework.
            //
            // We deliberately pass the raw integer 0 instead of constructing the OptionSet type
            // (which would require the new SDK symbol).
            //
            // Do not replace this with a direct typed call to the public API. Doing so would
            // make the file unbuildable on the project's minimum supported Xcode (26).
            // See the full compatibility notes on `configureAudioSessionAsync`.
            typealias ActivateFn = @convention(c) (
                AnyObject,
                Selector,
                UInt, // AVAudioSessionActivationOptions raw value (.none == 0)
                @escaping @convention(block) (Bool, Error?) -> Void
            ) -> Void

            let activateWithOptions = unsafe unsafeBitCast(imp, to: ActivateFn.self)

            let handler: @convention(block) (Bool, Error?) -> Void = { success, error in
                if let error {
                    #if DEBUG
                    print("[DirectStreamingPlayer] Async activate failed: \(error.localizedDescription)")
                    #endif
                    continuation.resume(returning: false)
                } else {
                    #if DEBUG
                    if !wasAlreadyPlayback {
                        print("[DirectStreamingPlayer] Audio session configured + activated asynchronously")
                    }
                    #endif
                    continuation.resume(returning: success)
                }
            }

            // Invoke with explicit scalar 0 for options.
            activateWithOptions(session, selector, 0, handler)
        }
    }

    /// Off-main-thread wrapper for the synchronous `setActive(true)` on iOS 26.x.
    ///
    /// Executes `setActive` on a global concurrent queue (userInitiated QoS) and bridges
    /// the result back via continuation. This keeps the `@MainActor` caller responsive
    /// and prevents the AVAudioSession runtime warning that is emitted when the blocking
    /// API is invoked directly from the main thread.
    ///
    /// - Note: Only used in the `< iOS 27` fallback path inside ``configureAudioSessionAsync()``.
    /// - Returns: `true` if activation succeeded.
    private static func activateSynchronouslyOffMainThread(session: AVAudioSession) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try session.setActive(true, options: [])
                    continuation.resume(returning: true)
                } catch {
                    #if DEBUG
                    print("[DirectStreamingPlayer] setActive (off-main) failed: \(error.localizedDescription)")
                    #endif
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Deactivation (symmetric to activation)

    /// Deactivates the audio session using the appropriate API for the runtime.
    ///
    /// - On iOS 27.0+: uses the non-blocking `deactivateWithOptions:completionHandler:` via dynamic dispatch.
    /// - On iOS 26.x: performs the synchronous `setActive(false)` off the main thread.
    ///
    /// All future explicit deactivation (e.g. on full stop, backgrounding with no active
    /// playback, or explicit teardown) must go through this method.
    ///
    /// - Returns: `true` on success (or no-op success under test/widget conditions).
    /// - SeeAlso: ``configureAudioSessionAsync()``
    @MainActor
    func deactivateAudioSessionAsync() async -> Bool {
        if Bundle.main.bundleURL.pathExtension == "appex" {
            return true
        }
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] Skipped audio session deactivation for tests...")
            #endif
            return true
        }

        let session = audioSession
        if #available(iOS 27.0, *) {
            return await Self.deactivateAsyncDynamic(session: session)
        } else {
            return await Self.deactivateSynchronouslyOffMainThread(session: session)
        }
    }

    @available(iOS 27.0, *)
    private static func deactivateAsyncDynamic(session: AVAudioSession) async -> Bool {
        await withCheckedContinuation { continuation in
            let selector = NSSelectorFromString("deactivateWithOptions:completionHandler:")

            guard session.responds(to: selector),
                  let imp = unsafe session.method(for: selector) else {
                continuation.resume(returning: false)
                return
            }

            // SAFETY: unsafeBitCast mirrors the pattern used for activation.
            // Required for exact C ABI (options + escaping completion block) and
            // dual Xcode 26/27+ source compatibility.
            typealias DeactivateFn = @convention(c) (
                AnyObject,
                Selector,
                UInt, // AVAudioSessionDeactivationOptions
                @escaping @convention(block) (Bool, Error?) -> Void
            ) -> Void

            let deactivateWithOptions = unsafe unsafeBitCast(imp, to: DeactivateFn.self)

            let handler: @convention(block) (Bool, Error?) -> Void = { success, error in
                if let error {
                    #if DEBUG
                    print("[DirectStreamingPlayer] Async deactivate failed: \(error.localizedDescription)")
                    #endif
                    continuation.resume(returning: false)
                } else {
                    #if DEBUG
                    print("[DirectStreamingPlayer] Audio session deactivated asynchronously")
                    #endif
                    continuation.resume(returning: success)
                }
            }

            deactivateWithOptions(session, selector, 0, handler)
        }
    }

    private static func deactivateSynchronouslyOffMainThread(session: AVAudioSession) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try session.setActive(false, options: [])
                    continuation.resume(returning: true)
                } catch {
                    #if DEBUG
                    print("[DirectStreamingPlayer] setActive(false) (off-main) failed: \(error.localizedDescription)")
                    #endif
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Thin async wrapper around ``configureAudioSessionAsync()``.
    ///
    /// Single owner for playback AVAudioSession category+activation for cold launch,
    /// stream switches, and tuning sound paths.
    ///
    /// Under `isTesting` (SSOT `SharedPlayerManager.isRunningInUITestMode`) this is a no-op.
    /// Prevents background audio side effects during tests / launch performance tests.
    ///
    /// - SeeAlso: ``configureAudioSessionAsync()``, ``startLocalClipPlayer(contentsOf:volume:numberOfLoops:)``,
    ///   `play()`, `startPlayback(context:)`.
    @MainActor
    func setupAudioSession() async {
        // Widget / extension safety: no-op when running in appex (see configureAudioSessionAsync).
        // The #available(iOS 27.0, *) + dynamic dispatch logic lives only inside the
        // configure implementation. It is never reached from widget extension compilations
        // (file excluded from that target) and is carefully written for dual Xcode 26 / 27+
        // source compatibility.
        if Bundle.main.bundleURL.pathExtension == "appex" {
            return
        }
        _ = await configureAudioSessionAsync()
    }
}
