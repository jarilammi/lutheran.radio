//
//  DirectStreamingPlayer+PlayerItemRecovery.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Player-item recovery domain: startup safety net (first-byte grace SSOT — never a 5 s
//  recreate of an unknown item), early ICY drop recreate, early-window transient recovery,
//  secured recreatePlayerItem, loading/item failure classification hooks.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public façade; this file owns one domain.
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is
//  file-scoped). Prefer this domain file over re-implementing attach / recovery
//  / catalog logic in call sites.
//
//  - SeeAlso: DirectStreamingPlayer.swift, DirectStreamingPlayer+SecuredPlayerItem.swift
//    (``makeSecuredPlayerItem(for:)``), StreamErrorType.from(error:),
//    DirectStreamingPlayer+PlaybackAttach.swift, CODING_AGENT.md
//    (Single Source of Truth Principles).
//

import Foundation
import Core
import WidgetSurface
@unsafe @preconcurrency import AVFoundation

extension DirectStreamingPlayer {
    // MARK: - PlayerItemRecovery domain
    //
    // Preferred end-state name for startup safety net, early ICY drop recreate, early-window
    // transient recovery, and secured recreatePlayerItem. Always rebuilds via
    // makeSecuredPlayerItem (resource loader + Core certificate path).

    @MainActor
    func cancelStartupSafetyNet() {
        startupSafetyNetWorkItem?.cancel()
        startupSafetyNetWorkItem = nil
    }
    // MARK: - Startup Safety Net (cold launch / stream-switch first attach)

    /// Formatted elapsed-seconds for DEBUG safety-net logs (no C-varargs `unsafe`).
    @MainActor
    private func startupSafetyNetElapsedText() -> String {
        let elapsed = currentAttachBeganAt.map { Date().timeIntervalSince($0) } ?? 0
        return elapsed.formatted(
            .number
                .precision(.fractionLength(2))
                .locale(Locale(identifier: "en_US_POSIX"))
        )
    }

    /// Host of the current secured item, or `"?"` when the asset is not an `AVURLAsset`.
    @MainActor
    private func startupSafetyNetHostText(for item: AVPlayerItem?) -> String {
        (item?.asset as? AVURLAsset)?.url.host ?? "?"
    }

    /// Delay until the next safety-net evaluation. Unknown + no error uses remaining
    /// ``earlyAttachFirstByteGraceSeconds``; ready-but-silent uses remaining loading grace
    /// plus debounce; failed/error fires almost immediately. Never a hard-coded `5.0`.
    ///
    /// - Returns: Positive delay in seconds (minimum 50 ms so the work item is not synchronous).
    /// - SeeAlso: ``earlyAttachFirstByteGraceSeconds``, ``earlyAttachLoadingGraceSeconds``,
    ///   ``scheduleStartupSafetyNet()``
    @MainActor
    func nextStartupSafetyNetDelaySeconds() -> TimeInterval {
        if let item = playerItem {
            if item.error != nil || item.status == .failed {
                return 0.05
            }
            switch item.status {
            case .unknown:
                return max(0.05, remainingEarlyAttachFirstByteGraceSeconds())
            case .readyToPlay:
                return max(
                    0.05,
                    remainingEarlyAttachLoadingGraceSeconds() + earlyAttachStallDebounceSeconds
                )
            case .failed:
                return 0.05
            @unknown default:
                return max(0.05, remainingEarlyAttachFirstByteGraceSeconds())
            }
        }
        return max(0.05, remainingEarlyAttachFirstByteGraceSeconds())
    }

    /// Whether a fresh attach used a cluster chosen before this mount.
    ///
    /// True only for ``PlaybackAttachContext/freshAttachAfterHardTeardown`` when a prior
    /// ``lastServerSelectionTime`` exists. That stamp is an earlier mount’s ping (still
    /// inside the 10 s throttle, inside the warm window, or last-good while a new ping
    /// runs). Cold launch and stream switch stay false so a small ping margin does not
    /// move those attaches. The first URL is still built immediately — this flag does
    /// not wait on the ping pair.
    ///
    /// - Parameters:
    ///   - context: Attach context for the URL that was just selected.
    ///   - hadPriorServerSelection: `lastServerSelectionTime != nil` at URL build.
    /// - Returns: `true` when the safety net may later leave this cluster if the item
    ///   is still unknown with no error and playback has not started.
    /// - SeeAlso: ``shouldLeaveInheritedClusterOnFirstByteSafetyNet(hasStartedPlaying:itemStatusUnknown:itemHasError:inheritedClusterFromEarlierMount:)``,
    ///   ``PlaybackAttachContext/freshAttachAfterHardTeardown``,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§4.5).
    static func attachInheritedClusterFromEarlierMount(
        context: PlaybackAttachContext,
        hadPriorServerSelection: Bool
    ) -> Bool {
        context == .freshAttachAfterHardTeardown && hadPriorServerSelection
    }

    /// Whether first-byte safety-net recreate may attach the other production host.
    ///
    /// Admitted only when this mount reused an earlier cluster, the item is still
    /// ``.unknown`` with no error, and audio has not started. A cluster that already
    /// started audio stays put. Soft-pause resume never sets the inherited flag and
    /// never schedules this net. An item error or a ready item uses the same-URL
    /// secured recreate instead of a host change.
    ///
    /// - Parameters:
    ///   - hasStartedPlaying: Engine has published audible playback for this mount.
    ///   - itemStatusUnknown: `AVPlayerItem.status == .unknown` (or no item yet).
    ///   - itemHasError: `AVPlayerItem.error != nil`.
    ///   - inheritedClusterFromEarlierMount: ``currentAttachInheritedClusterWithoutFirstByte``.
    /// - Returns: `true` when recreate should call ``urlWithOptimalServer(for:allowSameStreamWarmReuse:)``
    ///   on the other production cluster, then ``makeSecuredPlayerItem(for:)``.
    /// - SeeAlso: ``attachInheritedClusterFromEarlierMount(context:hadPriorServerSelection:)``,
    ///   ``alternateProductionClusterSubdomain(currentSubdomain:productionSubdomains:)``,
    ///   ``scheduleStartupSafetyNet()``,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§8).
    static func shouldLeaveInheritedClusterOnFirstByteSafetyNet(
        hasStartedPlaying: Bool,
        itemStatusUnknown: Bool,
        itemHasError: Bool,
        inheritedClusterFromEarlierMount: Bool
    ) -> Bool {
        guard inheritedClusterFromEarlierMount else { return false }
        guard !hasStartedPlaying else { return false }
        guard itemStatusUnknown, !itemHasError else { return false }
        return true
    }

    /// The other production cluster subdomain (`eu` / `us`), when one exists.
    ///
    /// - Parameters:
    ///   - currentSubdomain: Subdomain of the cluster that never delivered this mount’s first byte.
    ///   - productionSubdomains: ``servers`` subdomains, preferred order.
    /// - Returns: The first subdomain that differs, or `nil` when the list has no other host.
    /// - SeeAlso: ``shouldLeaveInheritedClusterOnFirstByteSafetyNet(hasStartedPlaying:itemStatusUnknown:itemHasError:inheritedClusterFromEarlierMount:)``,
    ///   ``SecurityConfiguration/preferredStreamingDomainSuffixes``
    static func alternateProductionClusterSubdomain(
        currentSubdomain: String,
        productionSubdomains: [String]
    ) -> String? {
        productionSubdomains.first { $0 != currentSubdomain }
    }

    /// Whether the startup safety net may ``recreatePlayerItem()`` right now.
    ///
    /// Reuses ``shouldAttemptEarlyAttachStallRecovery(item:rate:)`` so unknown + no error
    /// inside first-byte grace is refused. Audible `.readyToPlay` is never recreated.
    ///
    /// - Parameters:
    ///   - item: Current player item, if any.
    ///   - rate: Current `AVPlayer.rate`.
    /// - Returns: `true` when a last-resort secured recreate is admitted.
    /// - SeeAlso: ``shouldAttemptEarlyAttachStallRecovery(item:rate:)``,
    ///   ``scheduleStartupSafetyNet()``
    @MainActor
    func shouldStartupSafetyNetRecreate(item: AVPlayerItem?, rate: Float) -> Bool {
        let isActuallyPlaying = rate > 0.1 && (item?.status ?? currentItemStatus) == .readyToPlay
        if isActuallyPlaying { return false }
        guard let item else { return false }
        return shouldAttemptEarlyAttachStallRecovery(item: item, rate: rate)
    }

    /// Last-resort recreate for cold-launch, stream-switch, and fresh-attach first play.
    ///
    /// ``PlaybackAttachContext/freshAttachAfterHardTeardown`` schedules this net.
    /// ``PlaybackAttachContext/resume`` and soft-pause resume do not.
    ///
    /// Delay comes from ``nextStartupSafetyNetDelaySeconds()`` (first-byte grace for unknown
    /// items, loading grace for ready-but-silent). When the work item fires, admission is
    /// ``shouldStartupSafetyNetRecreate(item:rate:)`` — the same unknown-item predicate as
    /// stall recovery. A skip while first-byte grace remains reschedules the remainder;
    /// it does **not** abort in-flight DNS/TLS with a 5 s recreate.
    ///
    /// - Important: Do not call `play()` here. Kick policy still waits for `.readyToPlay`.
    /// - SeeAlso: ``earlyAttachFirstByteGraceSeconds``, ``shouldAttemptEarlyAttachStallRecovery(item:rate:)``,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§8).
    @MainActor
    func scheduleStartupSafetyNet() {
        guard initialPlaybackRetryCount < maxInitialRetries else { return }

        cancelStartupSafetyNet()
        let delay = nextStartupSafetyNetDelaySeconds()
        #if DEBUG
        print("[DirectStreamingPlayer] [Playback] Startup safety net: scheduled in \(delay.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "en_US_POSIX"))))s (first-byte grace=\(Int(earlyAttachFirstByteGraceSeconds))s)")
        #endif
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            Task { @MainActor in
                // intent-driven startup safety net.
                // Activation relies solely on: intent check + actual playback facts.
                guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
                    #if DEBUG
                    print("[DirectStreamingPlayer] startup safety net: resurrection suppressed by playbackIntent")
                    #endif
                    return
                }

                let rate = self.player?.rate ?? 0
                let item = self.playerItem
                let elapsedText = self.startupSafetyNetElapsedText()
                let host = self.startupSafetyNetHostText(for: item)
                let statusRaw = item?.status.rawValue ?? self.currentItemStatus.rawValue
                let errorDesc = item?.error.map { String(describing: $0) } ?? "nil"

                let isActuallyPlaying = rate > 0.1 &&
                    (item?.status ?? self.currentItemStatus) == .readyToPlay
                if isActuallyPlaying {
                    #if DEBUG
                    print("[DirectStreamingPlayer] [Playback] Startup safety net: skip — already playing (elapsed=\(elapsedText)s host=\(host))")
                    #endif
                    return
                }

                // Share the same hard budget as early-window recovery so stall recreates
                // and the safety net cannot stack into a multi-recreate storm.
                if self.initialPlaybackRetryCount >= self.maxInitialRetries {
                    #if DEBUG
                    let tc = self.player?.timeControlStatus.rawValue ?? -1
                    print("[DirectStreamingPlayer] [Playback] Startup safety net: budget already exhausted (\(self.initialPlaybackRetryCount)/\(self.maxInitialRetries)) elapsed=\(elapsedText)s status=\(statusRaw) error=\(errorDesc) host=\(host)")
                    print("[DirectStreamingPlayer] [Playback] Safety net terminal: hasPermanentError=\(self.hasPermanentError) | timeControlStatus=\(tc) | rate=\(rate) | currentItemStatus=\(statusRaw)")
                    #endif

                    if self.hasPermanentError {
                        self.safeOnStatusChange(isPlaying: false, reasonKey: "status_failed")
                    } else {
                        // One last secured recreate only — still no permanent red UX for
                        // pure transient ICY/Fig noise. Intent stays active so a later
                        // language switch or explicit play can recover.
                        #if DEBUG
                        print("[DirectStreamingPlayer] [Playback] Transient give-up: performing FINAL recreatePlayerItem() then suppressing severe status. No red popup. elapsed=\(elapsedText)s status=\(statusRaw) error=\(errorDesc) host=\(host)")
                        #endif
                        await self.recreateFromStartupSafetyNet()
                    }
                    return
                }

                if !self.shouldStartupSafetyNetRecreate(item: item, rate: rate) {
                    let remaining = self.remainingEarlyAttachFirstByteGraceSeconds()
                    #if DEBUG
                    print("[DirectStreamingPlayer] [Playback] Startup safety net: skip recreate — still loading (elapsed=\(elapsedText)s status=\(statusRaw) error=\(errorDesc) host=\(host) remainingFirstByte=\(remaining.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "en_US_POSIX"))))s)")
                    #endif
                    if remaining > 0 {
                        self.scheduleStartupSafetyNet()
                    }
                    return
                }

                self.initialPlaybackRetryCount += 1
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] Startup safety net: recreate — retry \(self.initialPlaybackRetryCount)/\(self.maxInitialRetries) elapsed=\(elapsedText)s status=\(statusRaw) error=\(errorDesc) host=\(host) hasStartedPlaying=\(self.hasStartedPlaying) rate=\(rate)")
                #endif
                await self.recreateFromStartupSafetyNet()
            }
        }
        startupSafetyNetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Secured recreate for the startup safety net.
    ///
    /// When ``shouldLeaveInheritedClusterOnFirstByteSafetyNet(hasStartedPlaying:itemStatusUnknown:itemHasError:inheritedClusterFromEarlierMount:)``
    /// is true, points ``currentSelectedServer`` at the other production host and
    /// rebuilds the URL through ``urlWithOptimalServer(for:allowSameStreamWarmReuse:)``
    /// (no warm reuse, no wait for a new ping pair) before ``makeSecuredPlayerItem(for:)``.
    /// Does not stamp ``lastServerSelectionTime`` — leaving a silent cluster is not a
    /// measured ping. Otherwise recreates the same URL. Soft-pause resume does not
    /// call this.
    ///
    /// - SeeAlso: ``scheduleStartupSafetyNet()``, ``recreatePlayerItem(securedURL:)``,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§8).
    @MainActor
    func recreateFromStartupSafetyNet() async {
        let item = playerItem
        let status = item?.status ?? currentItemStatus
        let shouldLeave = Self.shouldLeaveInheritedClusterOnFirstByteSafetyNet(
            hasStartedPlaying: hasStartedPlaying,
            itemStatusUnknown: item == nil || status == .unknown,
            itemHasError: item?.error != nil,
            inheritedClusterFromEarlierMount: currentAttachInheritedClusterWithoutFirstByte
        )
        guard shouldLeave,
              let alternateSubdomain = Self.alternateProductionClusterSubdomain(
                currentSubdomain: currentSelectedServer.subdomain,
                productionSubdomains: Self.servers.map(\.subdomain)
              ),
              let alternate = Self.servers.first(where: { $0.subdomain == alternateSubdomain })
        else {
            recreatePlayerItem()
            return
        }

        currentAttachInheritedClusterWithoutFirstByte = false
        currentSelectedServer = alternate
        #if DEBUG
        print("[DirectStreamingPlayer] [Playback] Startup safety net: leaving inherited cluster for \(alternate.name) (this mount has no first byte)")
        #endif
        let url = await urlWithOptimalServer(for: selectedStream, allowSameStreamWarmReuse: false)
        recreatePlayerItem(securedURL: url)
    }
    @MainActor
    func activatePlaybackTeardownGuard() {
        isPlaybackTeardownActive = true
        cancelEarlyICYDropRecreate()
        cancelStartupSafetyNet()
    }

    @MainActor
    func clearPlaybackTeardownGuard() {
        isPlaybackTeardownActive = false
    }

    /// Activates the teardown guard on the main actor without requiring the caller to be MainActor-isolated.
    func activatePlaybackTeardownGuardFromStop() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { activatePlaybackTeardownGuard() }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { self.activatePlaybackTeardownGuard() } }
        }
    }

    @MainActor
    func scheduleEarlyICYDropRecreate(rate: Float) {
        guard !isPlaybackTeardownActive else { return }
        earlyICYDropRecreateTask?.cancel()
        earlyICYDropRecreateTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard let self else { return }
            #if DEBUG
            print("[DirectStreamingPlayer] [Playback] Early timeControl drop on fresh ICY item (rate=\(rate)) — early-window recovery")
            #endif
            _ = await self.attemptEarlyWindowTransientRecovery(
                reason: "timeControlPaused-early",
                allowWhileDeferringFirstPlayKick: false
            )
        }
    }
    
    @MainActor
    func cancelEarlyICYDropRecreate() {
        earlyICYDropRecreateTask?.cancel()
        earlyICYDropRecreateTask = nil
    }

    /// Seconds remaining in the ready-but-silent loading grace (0 when expired or not started).
    @MainActor
    func remainingEarlyAttachLoadingGraceSeconds() -> TimeInterval {
        remainingAttachGraceSeconds(window: earlyAttachLoadingGraceSeconds)
    }

    /// Seconds remaining in the unknown-item first-byte grace (0 when expired or not started).
    ///
    /// - SeeAlso: ``earlyAttachFirstByteGraceSeconds``, ``shouldAttemptEarlyAttachStallRecovery(item:rate:)``
    @MainActor
    func remainingEarlyAttachFirstByteGraceSeconds() -> TimeInterval {
        remainingAttachGraceSeconds(window: earlyAttachFirstByteGraceSeconds)
    }

    /// Seconds remaining in `window` since ``currentAttachBeganAt``.
    ///
    /// No clock yet (observers before attach mark) is treated as the full window so we do
    /// not recreate from a zero-delay path.
    @MainActor
    private func remainingAttachGraceSeconds(window: TimeInterval) -> TimeInterval {
        guard let began = currentAttachBeganAt else {
            return window
        }
        let elapsed = Date().timeIntervalSince(began)
        return max(0, window - elapsed)
    }

    /// Pure stall-admission policy (no engine instance). Unknown + no error is refused until
    /// first-byte grace elapses; `.failed` / `item.error` and ready-but-silent are admitted
    /// when the shared recreate budget remains.
    ///
    /// - Parameters:
    ///   - hasStartedPlaying: Stable audible play already achieved for this attach.
    ///   - retryCount: ``initialPlaybackRetryCount``.
    ///   - maxRetries: ``maxInitialRetries``.
    ///   - rate: Current `AVPlayer.rate`.
    ///   - itemStatus: Current `AVPlayerItem.status`.
    ///   - itemHasError: `item.error != nil`.
    ///   - remainingFirstByteGraceSeconds: Remaining ``earlyAttachFirstByteGraceSeconds``.
    /// - Returns: `true` when a stall-class early recreate is allowed to proceed.
    /// - SeeAlso: ``shouldAttemptEarlyAttachStallRecovery(item:rate:)``,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§8).
    static func shouldAttemptEarlyAttachStallRecovery(
        hasStartedPlaying: Bool,
        retryCount: Int,
        maxRetries: Int,
        rate: Float,
        itemStatus: AVPlayerItem.Status,
        itemHasError: Bool,
        remainingFirstByteGraceSeconds: TimeInterval
    ) -> Bool {
        guard !hasStartedPlaying else { return false }
        guard retryCount < maxRetries else { return false }
        guard rate < 0.1 else { return false }
        if itemHasError { return true }
        switch itemStatus {
        case .failed:
            return true
        case .readyToPlay:
            // Ready but silent — short patience already applied by the caller's debounce.
            return true
        case .unknown:
            // Progressive ICY / cold DNS: unknown + no error is normal loading until first-byte grace.
            return remainingFirstByteGraceSeconds <= 0
        @unknown default:
            return remainingFirstByteGraceSeconds <= 0
        }
    }

    /// Whether Connecting Play should nudge the existing item instead of no-op.
    ///
    /// Fresh connect (first-byte grace remaining and no safety-net retry yet) stays a no-op
    /// so a 1 s connect does not stack ``attachAndPlay``. After first-byte grace, or after
    /// the safety net has already retried, Play is stale and must not be swallowed forever.
    ///
    /// - Parameters:
    ///   - remainingFirstByteGraceSeconds: Remaining ``earlyAttachFirstByteGraceSeconds``.
    ///   - initialPlaybackRetryCount: Shared recreate budget consumed so far.
    /// - Returns: `true` when Connecting is stale.
    /// - SeeAlso: ``SharedPlayerManager/userRequestedPlay()``, ``nudgeStaleConnectingPlay()``
    static func isConnectingAttachStale(
        remainingFirstByteGraceSeconds: TimeInterval,
        initialPlaybackRetryCount: Int
    ) -> Bool {
        remainingFirstByteGraceSeconds <= 0 || initialPlaybackRetryCount > 0
    }

    /// Whether "buffer not likely to keep up + rate 0" may enter early-window recovery.
    ///
    /// Returns `false` while the secured item is still legitimately loading
    /// (`status == .unknown`, no error) inside ``earlyAttachFirstByteGraceSeconds``.
    /// Hard errors and post-ready stuck rate always return `true` when the early budget remains.
    ///
    /// - Parameters:
    ///   - item: Current `AVPlayerItem` under observation.
    ///   - rate: Current `AVPlayer.rate`.
    /// - Returns: `true` when a stall-class early recreate is allowed to proceed.
    /// - SeeAlso: ``attemptEarlyWindowTransientRecovery(reason:allowWhileDeferringFirstPlayKick:)``,
    ///   ``earlyAttachFirstByteGraceSeconds``, ``earlyAttachLoadingGraceSeconds``,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§8).
    @MainActor
    func shouldAttemptEarlyAttachStallRecovery(item: AVPlayerItem, rate: Float) -> Bool {
        Self.shouldAttemptEarlyAttachStallRecovery(
            hasStartedPlaying: hasStartedPlaying,
            retryCount: initialPlaybackRetryCount,
            maxRetries: maxInitialRetries,
            rate: rate,
            itemStatus: item.status,
            itemHasError: item.error != nil,
            remainingFirstByteGraceSeconds: remainingEarlyAttachFirstByteGraceSeconds()
        )
    }

    /// Silent recovery for transient ICY / Fig / decoder noise on a fresh attach.
    ///
    /// This is the single decision gate for early-window recovery. Callers (KVO, buffer
    /// observers, item `.failed`, resource-loader errors, loading errors) pass a diagnostic
    /// `reason` only. The gate enforces:
    /// - teardown suppression
    /// - pre-stable-play window (`!hasStartedPlaying`)
    /// - per-stream retry budget (`initialPlaybackRetryCount` / `maxInitialRetries`) —
    ///   **each successful admission increments the count** so the budget is a hard cap
    /// - ``SharedPlayerManager/canProceedWithPlayback()`` (sticky pause / security / clear)
    ///
    /// Stall-class callers must also pass ``shouldAttemptEarlyAttachStallRecovery(item:rate:)``
    /// so normal first-byte loading is not treated as an immediate recreate.
    ///
    /// On success it schedules ``recreatePlayerItem()``, which always rebuilds a **secured**
    /// item (resource loader + DNSSEC/cert path) under the current ``playbackAttachGeneration``.
    /// Permanent failures never enter here.
    ///
    /// - Parameters:
    ///   - reason: DEBUG diagnostic label for the recovery trigger.
    ///   - allowWhileDeferringFirstPlayKick: When `false`, skips while the first audible kick
    ///     is still waiting on `.readyToPlay` (used for pure timeControl pauses that often
    ///     resolve without recreate). When `true`, recovers even if the first kick is deferred
    ///     (item failure / resource-loader errors cannot wait for ready).
    /// - Returns: `true` if ``recreatePlayerItem()`` was invoked.
    /// - SeeAlso: `recreatePlayerItem()`, `handleItemStatusFailure(_:)`,
    ///   `shouldAttemptEarlyAttachStallRecovery(item:rate:)`,
    ///   `isInInitialRecoveryWindow`, docs/cold-launch-streamplay-regression-checklist.md (§8).
    @MainActor
    @discardableResult
    func attemptEarlyWindowTransientRecovery(
        reason: String,
        allowWhileDeferringFirstPlayKick: Bool
    ) async -> Bool {
        guard !isPlaybackTeardownActive else { return false }
        guard !hasStartedPlaying else { return false }
        if !allowWhileDeferringFirstPlayKick && isDeferringFirstPlayKick {
            #if DEBUG
            print("[DirectStreamingPlayer] early-window recovery skipped (\(reason)) — awaiting readyToPlay first-play kick")
            #endif
            return false
        }
        guard initialPlaybackRetryCount < maxInitialRetries else {
            #if DEBUG
            print("[DirectStreamingPlayer] early-window recovery budget exhausted (\(reason)) — \(initialPlaybackRetryCount)/\(maxInitialRetries)")
            #endif
            return false
        }
        guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
            #if DEBUG
            print("[DirectStreamingPlayer] early-window recovery suppressed by playbackIntent (\(reason))")
            #endif
            return false
        }
        // Hard cap: every admitted recovery consumes one budget unit (never sticky-at-1).
        initialPlaybackRetryCount += 1
        #if DEBUG
        print("[DirectStreamingPlayer] early-window recovery → recreatePlayerItem | reason=\(reason) | retryCount=\(initialPlaybackRetryCount)/\(maxInitialRetries)")
        #endif
        recreatePlayerItem()
        return true
    }
    
    /// Rebuilds the current live `AVPlayerItem` on the secured resource-loader path.
    ///
    /// Canonical recovery tool for transient ICY/Fig/decoder noise and mid-session stalls.
    /// Always creates the replacement item via ``makeSecuredPlayerItem(for:)`` so DNSSEC and
    /// runtime certificate validation remain in force. Single-flight (`recreateInFlight`);
    /// suppressed while `isPlaybackTeardownActive`. Captures ``playbackAttachGeneration`` at
    /// entry and aborts if a concurrent ``stop(reason:completion:silent:)`` advanced it
    /// (stream-switch teardown or user pause supersedes the in-flight recreate).
    /// Rebinds player-level and item-level observers, then restarts only when
    /// ``shouldAllowAudiblePlaybackKick(startedAt:)`` still allows audio (entry generation,
    /// not ``isCurrentlyAttemptingPlayback``). Recreate uses the same keep-up kick policy as
    /// cold launch / stream switch (not `playImmediately` at `.readyToPlay`).
    ///
    /// - Parameters:
    ///   - securedURL: Replacement stream URL. `nil` rebuilds the current item’s URL
    ///     (mid-session stall, ready-but-silent, item error). The startup safety net
    ///     passes the other production host only when this mount inherited a cluster
    ///     and still has no first byte. Either URL goes through ``makeSecuredPlayerItem(for:)``.
    /// - SeeAlso: `attemptEarlyWindowTransientRecovery(reason:allowWhileDeferringFirstPlayKick:)`,
    ///   `makeSecuredPlayerItem(for:)`, `setupPlaybackObservers()`,
    ///   ``recreateFromStartupSafetyNet()``,
    ///   ``applyLiveAttachAudibleKickIfReady(itemIsReadyToPlay:isPlaybackLikelyToKeepUp:startedAt:)``,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§8).
    func recreatePlayerItem(securedURL: URL? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !self.isPlaybackTeardownActive else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] recreatePlayerItem: suppressed — playback teardown active")
                #endif
                return
            }
            guard !self.recreateInFlight else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] recreatePlayerItem: coalesced — already in flight")
                #endif
                return
            }
            let generationAtStart = self.playbackAttachGeneration
            self.recreateInFlight = true
            defer { self.recreateInFlight = false }
            
            #if DEBUG
            print("[DirectStreamingPlayer] Recreating secured player item (transient recovery)")
            #endif
            
            let currentURL: URL
            if let securedURL {
                currentURL = securedURL
            } else if let urlAsset = self.playerItem?.asset as? AVURLAsset {
                currentURL = urlAsset.url
            } else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] Cannot recreate: no valid URL asset | hasStartedPlaying=\(self.hasStartedPlaying) | initialPlaybackRetryCount=\(self.initialPlaybackRetryCount) | playerItem=\(self.playerItem != nil) | this often happens during stream switch races")
                #endif
                return
            }
            self.cancelEarlyICYDropRecreate()
            
            // Clear item-level observations before replacing the item.
            self.playerItemObservations.forEach { $0.invalidate() }
            self.playerItemObservations.removeAll()

            // Stream-switch / user stop may have advanced generation after we entered.
            guard generationAtStart == self.playbackAttachGeneration else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] recreatePlayerItem: discarded — attach generation advanced")
                #endif
                return
            }
            guard !self.isPlaybackTeardownActive else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] recreatePlayerItem: discarded — teardown became active")
                #endif
                return
            }
            
            // Security invariant: replacement items must use the resource-loader path
            // (never a bare AVURLAsset without the streaming delegate).
            let newItem = self.makeSecuredPlayerItem(for: currentURL)
            
            self.player?.replaceCurrentItem(with: newItem)
            self.playerItem = newItem
            self.bindAttachedItemToSelectedStream()
            self.clearPlaybackTeardownGuard()
            // Fresh loading grace for the replacement item (prefer one recreate settling cleanly
            // over a second recreate while tracks are still attaching).
            self.currentAttachBeganAt = Date()
            
            // Rebind player-level KVO + ICY, then item-level buffer/status observers.
            self.setupPlaybackObservers()
            self.addObservers()
            
            guard await self.shouldAllowAudiblePlaybackKick(startedAt: generationAtStart) else {
                #if DEBUG
                print("[DirectStreamingPlayer] recreatePlayerItem: audible restart suppressed (intent / soft-pause / teardown / generation)")
                #endif
                self.isDeferringFirstPlayKick = false
                self.player?.pause()
                self.player?.rate = 0.0
                return
            }

            guard generationAtStart == self.playbackAttachGeneration else {
                #if DEBUG
                print("[DirectStreamingPlayer] [Playback] recreatePlayerItem: discarded after kick check — generation advanced")
                #endif
                self.player?.pause()
                self.player?.rate = 0.0
                return
            }
            
            // Restart only when still allowed — Icecast `.readyToPlay` is not a healthy
            // live buffer; chrome-publishing kick waits for `isPlaybackLikelyToKeepUp`.
            await self.applyLiveAttachAudibleKickIfReady(
                itemIsReadyToPlay: newItem.status == .readyToPlay,
                isPlaybackLikelyToKeepUp: newItem.isPlaybackLikelyToKeepUp,
                startedAt: generationAtStart
            )
            
            #if DEBUG
            print("[DirectStreamingPlayer] Secured player item recreated (item.status: \(newItem.status.rawValue))")
            #endif
        }
    }
    func handleLoadingError(_ error: Error) async {
        let errorType = StreamErrorType.from(error: error)
        hasPermanentError = errorType.isPermanent
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Loading Error] Type: \(errorType), isPermanent: \(errorType.isPermanent)")
        print("[DirectStreamingPlayer] [Loading Error] Error: \(error.localizedDescription)")
        #endif
        
        if let urlError = error as? URLError {
            switch urlError.code {
            case .serverCertificateUntrusted, .secureConnectionFailed:
                #if DEBUG
                print("[DirectStreamingPlayer] [Loading Error] SSL/Certificate error detected")
                #endif
                safeOnStatusChange(isPlaying: false, reasonKey: "status_security_failed")
                
            case .fileDoesNotExist:
                #if DEBUG
                print("[DirectStreamingPlayer] [Loading Error] Hard server error (resource missing)")
                #endif
                safeOnStatusChange(isPlaying: false, reasonKey: "status_failed")
                
            case .cannotFindHost, .dnsLookupFailed:
                #if DEBUG
                print("[DirectStreamingPlayer] [Loading Error] DNS lookup error (may be DNSSEC-unvalidated when policy active) — treating as transient")
                #endif
                // DNS lookup (including DNSSEC validation failure when
                // requiresDNSSECValidation is active) is recoverable in the early window.
                fallthrough
                
            default:
                #if DEBUG
                print("[DirectStreamingPlayer] [Loading Error] Transient error detected")
                #endif
                safeOnStatusChange(isPlaying: false, reasonKey: "status_buffering")
                
                if await attemptEarlyWindowTransientRecovery(
                    reason: "loadingError-url-\(urlError.code.rawValue)",
                    allowWhileDeferringFirstPlayKick: true
                ) {
                    return
                }
            }
        } else if !errorType.isPermanent {
            #if DEBUG
            print("[DirectStreamingPlayer] [Loading Error] Non-URL transient — early-window recovery path")
            #endif
            safeOnStatusChange(isPlaying: false, reasonKey: "status_buffering")
            if await attemptEarlyWindowTransientRecovery(
                reason: "loadingError-nonURL",
                allowWhileDeferringFirstPlayKick: true
            ) {
                return
            }
        } else {
            #if DEBUG
            print("[DirectStreamingPlayer] [Loading Error] Permanent non-URL error")
            #endif
            safeOnStatusChange(isPlaying: false, reasonKey: errorType.statusString)
        }
        
        // Terminal path: classified failure reaches SharedPlayerManager (intent preserved for
        // auto-resume on stream switch). `streamDidFail` is emitted inside mark… after mutation.
        await SharedPlayerManager.shared.markPlaybackStoppedByStreamFailure(errorType)
        stop()
    }

    func handleNetworkInterruption() {
        stop()
        let interruptionDelay: TimeInterval = isLowEfficiencyMode ? 1.0 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + interruptionDelay) { [weak self] in
            guard let self = self, self.delegate != nil else { return }
            // Emit a proper status_* key (never button titles or popup titles as reasonKey).
            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_paused")
        }
    }
    
    func handlePlaybackError(_ error: Error?) {
        #if DEBUG
        if let avError = error as? AVError {
            print("[DirectStreamingPlayer] Playback error: code=\(avError.code.rawValue), desc=\(avError.localizedDescription)")
        }
        #endif
        // Route every AV/item failure through the same classification + early-window gate.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let item = self.playerItem {
                await self.handleItemStatusFailure(item)
            } else if let error {
                await self.handleLoadingError(error)
            }
        }
    }

    /// Central decision point for `.failed` status on an `AVPlayerItem`.
    ///
    /// Answers: is this self-healing transient noise on a fresh ICY attach (recover with
    /// secured ``recreatePlayerItem()``), or a real permanent failure that should surface
    /// via ``SharedPlayerManager/markPlaybackStoppedByStreamFailure(_:)``?
    ///
    /// Combines:
    /// - ``StreamErrorType/from(error:)`` classification (decoder / Fig noise → transient)
    /// - The fresh-item budget (`!hasStartedPlaying` + `initialPlaybackRetryCount`)
    /// - Intent check via ``SharedPlayerManager/canProceedWithPlayback()``
    ///
    /// After a user stream switch, `switchToStream` + `resetInitialPlaybackCountersForNewStream`
    /// give the new item a clean budget so prior-stream noise cannot poison the first attempt.
    /// Terminal failure preserves playback intent (typically `.shouldBePlaying`) so a language
    /// switch can auto-resume without an extra play tap.
    ///
    /// - Precondition: Called on a `.failed` KVO delivery for the current `playerItem`.
    /// - Postcondition: Either ``recreatePlayerItem()`` was scheduled (transient) or a terminal
    ///   status was emitted and the player was stopped (permanent / budget exhausted).
    ///
    /// - SeeAlso: `StreamErrorType.from(error:)`, `attemptEarlyWindowTransientRecovery`,
    ///   `switchToStream(_:)`, `resetInitialPlaybackCountersForNewStream()`,
    ///   `recreatePlayerItem()`, `RadioPlayerCoordinator.handleStatusChange`,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§6.12, §8.7), CODING_AGENT.md
    @MainActor
    func handleItemStatusFailure(_ item: AVPlayerItem) async {
        let error = item.error
        let errorType = StreamErrorType.from(error: error)

        hasPermanentError = errorType.isPermanent

        if !errorType.isPermanent {
            if await attemptEarlyWindowTransientRecovery(
                reason: "itemStatusFailed",
                allowWhileDeferringFirstPlayKick: true
            ) {
                return
            }
        }

        // Permanent, or late/exhausted transient — surface failure without sticky user pause.
        safeOnStatusChange(isPlaying: false, reasonKey: errorType.statusString)
        await SharedPlayerManager.shared.markPlaybackStoppedByStreamFailure(errorType)
        stop()
    }
}
