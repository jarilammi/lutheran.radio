//
//  RadioPlayerCoordinator+StreamSwitch.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Stream-switch / language domain for RadioPlayerCoordinator (mechanical split).
//
//  Owns: main-app flag-tap orchestration (`handleLanguageSelection` →
//  `completeStreamSwitch`), widget/LA silent reconciliation
//  (`handleWidgetSwitchToLanguage` → `switchToStreamFromWidget`), external /
//  deep-link / Siri-adjacent entry (`handleSwitchToLanguage`), session language
//  snapshot updates (`updateUserDefaultsLanguage`), and VoiceOver
//  `announceSwitchedToLanguage`.
//
//  Does not own: engine prep SSOT (`DirectStreamingPlayer.switchToStream`),
//  visual/intent SSOT (`SharedPlayerManager`), tuning delight clips (`+Tuning`),
//  pending-action drain (`+PendingActions` — calls into this domain for switch),
//  play/pause toggle shims (remain on the primary coordinator file), status /
//  chrome distribution (`updateUI` / `handleStatusChange` in `+StatusDistribution`),
//  or Core security.
//
//  Stored debounce stamps (`streamSwitchWorkItem`, `streamSwitchTask`,
//  `lastStreamSwitchTime`, `streamSwitchDebounceInterval`) and selection index
//  remain on the primary type body (extensions cannot declare stored properties);
//  this file owns the behavior that mutates them.
//
//  Public/entry surfaces on the same type:
//  - ``handleSwitchToLanguage(_:)`` — SceneDelegate / deep-link / external
//  - ``handleWidgetSwitchToLanguage(_:actionId:)`` — widget/LA pending switch
//  - ``updateUserDefaultsLanguage(_:)`` — awaited destination language + privacy-gated liveness
//  - ``handleLanguageSelection(at:)`` — LanguageSelectorView / PlayerViewModel
//
//  Canonical private orchestrators (same type, file-private):
//  - ``completeStreamSwitch(stream:index:)`` — main-app full UX (tuning + needle)
//  - ``switchToStreamFromWidget(to:index:actionId:)`` — silent widget reconciliation
//
//  - SeeAlso: ``DirectStreamingPlayer/switchToStream(_:)``,
//    ``SharedPlayerManager/play()``, ``SharedPlayerManager/userRequestedPlay()``,
//    ``SharedPlayerManager/resetToPrePlayForNewStream(preserveActiveSleepTimer:)``,
//    RadioPlayerCoordinator.swift (isolation map),
//    docs/cold-launch-streamplay-regression-checklist.md,
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import UIKit
import WidgetKit
import Core
import WidgetSurface

extension RadioPlayerCoordinator {

    // MARK: - Stream choice / language switch paths (architectural note)
    //
    // All user-driven "change stream" flows converge on clearly separated responsibilities
    // (see CODING_AGENT.md Single Source of Truth Principles):
    //
    // - `DirectStreamingPlayer.switchToStream(_:)` — the **single source of truth** for
    //   *engine preparation* on any user-initiated choice (flag, widget, Siri, etc.).
    //   Performs: set model, reset transients, awaited silent streamSwitch stop (lang change),
    //   reset per-stream attempt counters. Always await when ordering with stop/play matters.
    //
    // - `RadioPlayerCoordinator` (this domain file):
    //   - `completeStreamSwitch` — canonical **main-app** full orchestration for flag taps.
    //     Owns tuning sound, prePlay hold coordination, intent guards, play sequencing,
    //     and UI side effects. The primary "user tapped a language" path.
    //   - `switchToStreamFromWidget(to:index:actionId:)` — canonical **widget/LA reconciliation**
    //     (silent, no tuning/needle). Thinly wrapped by `handleWidgetSwitchToLanguage`.
    //   - `handleWidgetSwitchToLanguage` — public entry (with actionId dedup + debounce)
    //     that delegates to the widget canonical.
    //   - `handleSwitchToLanguage` — external (Siri/shortcut/deep-link) path. Uses the
    //     engine SSOT + reset/play but is kept on a separate attach style for minimality;
    //     does not go through completeStreamSwitch (no main-app tuning expected for external).
    //   - `handleLanguageSelection` — entry from LanguageSelectorView taps (debounce +
    //     optimistic prePlay when appropriate, then delegates to completeStreamSwitch).
    //
    // - Playback initiation (separate SSOT from stream choice):
    //   - Explicit user "start/resume" requests use `SharedPlayerManager.userRequestedPlay()`
    //     (the designated single entry). See handlePlayAction,
    //     handleUserTogglePlayback (play branch), and all external surfaces.
    //   - Internal continuation when playback intent is already active (the resume branches
    //     of the two canonical switch methods `completeStreamSwitch` and `switchToStreamFromWidget`),
    //     cold launch, and recovery may call `play()` directly. The rule and justification
    //     are stated in the `///` docs on those methods and the Precondition on
    //     `userRequestedPlay()`.
    //
    // - `SharedPlayerManager` — owns `currentVisualState`, `currentPlaybackIntent`,
    //   `resetToPrePlayForNewStream`, resurrection rules, persisted widget snapshot,
    //   cross-process Darwin signaling, and the actual `play()` / `stop()` execution.
    //   Its `switchToStream` is the nonisolated signaling façade: widget context → schedule
    //   + Darwin; main-app context → forwards directly to engine.
    //
    // Widget paths originate from optimistic state + pending action + Darwin notification,
    // then land in `handleWidgetSwitchToLanguage` (or the Live Activity intent path via SPM).
    //
    // AGENT NOTE: Never re-introduce manual "setSelectedStreamModelOnly + resetTransient
    // + stop + resetCounters" sequences anywhere. Route engine work exclusively through
    // `DirectStreamingPlayer.switchToStream`. Main-app flag UX lives in `completeStreamSwitch`.
    // Widget reconciliation lives in `switchToStreamFromWidget`. Siri/external use SPM.switchToStream
    // + reset + userRequestedPlay (non-UI paths).
    // All explicit play initiation must use userRequestedPlay (or end at the permitted direct
    // `play()` sites after an active playback intent check). The two canonical switch resume
    // branches deliberately use direct `play()` (internal continuation of active intent).
    // See the `///` on `switchToStreamFromWidget`, `completeStreamSwitch`, `userRequestedPlay`,
    // and `play()` for the full analysis and "keep as-is" rule.
    // Update this block + the `///` docs on the four symbols together on any architecture change.

    // MARK: - External / deep-link language switch

    /// External / Siri / deep-link / shortcut driven language switch entry point.
    ///
    /// Performs engine prep via `DirectStreamingPlayer.switchToStream`, plays the
    /// special tuning sound + needle animation (unlike pure widget reconciliation),
    /// respects current playback intent, and ends by announcing the switch to
    /// VoiceOver via `announceSwitchedToLanguage`.
    ///
    /// - Parameter languageCode: Target ISO code (must match one of the 5 streams).
    ///
    /// - SeeAlso: `completeStreamSwitch`, `switchToStreamFromWidget(to:index:actionId:)`,
    ///   `announceSwitchedToLanguage(_:)`, SceneDelegate (URL handling),
    ///   RadioPlaybackIntents (related Siri flow).
    func handleSwitchToLanguage(_ languageCode: String) {
        Task { @MainActor in
            #if DEBUG
            print("[RadioPlayerCoordinator] handleSwitchToLanguage started for: \(languageCode)")
            #endif

            guard let targetStream = DirectStreamingPlayer.availableStreams.first(where: { $0.languageCode == languageCode }),
                  let targetIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == languageCode }) else {
                #if DEBUG
                print("[RadioPlayerCoordinator] handleSwitchToLanguage: target stream not found for \(languageCode)")
                #endif
                return
            }

            selectedStreamIndex = targetIndex
            viewModel?.selectedStreamIndex = targetIndex
            backgroundImageController.update(for: targetStream)
            setIsSwitchingStream(true)
            defer { setIsSwitchingStream(false) }

            // Destination language before engine prep (hold when intent allows play; stamp-only
            // when sticky pause / locked so mid-switch saves cannot re-persist the prior code).
            let mayResume = await SharedPlayerManager.shared.canProceedWithPlayback()
            if mayResume {
                let intent = await SharedPlayerManager.shared.currentPlaybackIntent
                await SharedPlayerManager.shared.resetToPrePlayForNewStream(
                    preserveActiveSleepTimer: intent == .sleepTimer,
                    connectingLanguageCode: targetStream.languageCode
                )
                updateUI(for: .prePlay)
            } else {
                await SharedPlayerManager.shared.stampStreamSwitchDestinationLanguage(targetStream.languageCode)
                await updateUserDefaultsLanguage(targetStream.languageCode)
            }

            #if DEBUG
            print("[RadioPlayerCoordinator] handleSwitchToLanguage — engine prep via switchToStream")
            #endif
            await streamingPlayer.switchToStream(targetStream)

            #if DEBUG
            print("[RadioPlayerCoordinator] Playing tuning sound (external switch path)")
            #endif
            await playTuningSound(animateNeedleTo: targetIndex)

            // Await destination language before further intent/UI work that can saveCurrentState.
            await updateUserDefaultsLanguage(targetStream.languageCode)
            SharedPlayerManager.persistLiveActivityLanguageMirror(targetStream.languageCode)

            // SwiftUI selector observes viewModel.selectedStreamIndex (matchedGeometryEffect animates)

            if await SharedPlayerManager.shared.canProceedWithPlayback() {
                #if DEBUG
                print("[RadioPlayerCoordinator] ▶ Starting playback after switch (intent allows)")
                #endif

                try? await Task.sleep(for: .seconds(0.5))

                handlePlayAction()
            } else {
                #if DEBUG
                print("[RadioPlayerCoordinator] ⏸ Intent blocks playback after switch (userPaused, securityLocked, or cleared)")
                #endif
                updateUI(for: .userPaused)
                await SharedPlayerManager.shared.clearStreamSwitchDestinationLanguageIfNotHolding()
            }

            announceSwitchedToLanguage(targetStream)

            #if DEBUG
            print("[RadioPlayerCoordinator] handleSwitchToLanguage completed for \(languageCode)")
            #endif
        }
    }

    // MARK: - Widget / Live Activity language switch

    /// Entry point for widget / Live Activity / pending-action reconciliation of a stream/language switch.
    ///
    /// Performs guard, deduplication, and debounce, then delegates to the canonical
    /// `switchToStreamFromWidget(to:index:actionId:)` for the actual engine + intent + play orchestration.
    /// Never plays tuning sound or animates the needle (those are main-app flag-tap only).
    ///
    /// - Parameters:
    ///   - languageCode: Target stream language code (e.g. "en", "fi").
    ///   - actionId: Unique ID for this pending widget action (used for dedup + clearing).
    ///
    /// - Important: Must respect `currentPlaybackIntent`. Does not auto-resume when user has
    ///   an explicit `.userPaused` (or `.securityLocked` / `.cleared`).
    ///
    /// - SeeAlso: `switchToStreamFromWidget(to:index:actionId:)`, `completeStreamSwitch`,
    ///   `DirectStreamingPlayer.switchToStream`, `SharedPlayerManager.currentPlaybackIntent`,
    ///   `SharedPlayerManager.resetToPrePlayForNewStream`, `SharedPlayerManager.play`,
    ///   CODING_AGENT.md (Single Source of Truth Principles + "Cross-target shared source files"),
    ///   <doc:Architecture>.
    ///
    /// AGENT NOTE: handleWidgetSwitchToLanguage is the *only* public entry for widget-driven
    /// language changes into the main app. The actionId/processed/debounce wrapper must stay here.
    /// Core orchestration (reset/switchToStream/play sequencing) lives in the private canonical below.
    /// Update both this doc and the canonical on any change to the widget path.
    func handleWidgetSwitchToLanguage(_ languageCode: String, actionId: String) {
        guard !processedActionIds.contains(actionId) else { return }
        processedActionIds.insert(actionId)

        // Always process the latest widget language selection (cancel any prior pending workItem).
        // The 2 s debounce is removed because:
        // - processedActionIds already dedups exact re-deliveries of the same actionId
        // - workItem cancel + last dispatch wins for rapid different-lang selections (the
        //   exact "paused sv -> en" flow).
        // - For paused state a language choice must be applied so the subsequent play uses it
        //   (see alignment in play() + setUserIntentToPlay).
        // Rapid hammering protection is still provided by the engine (switchToStream silent path)
        // and the blocked/no-auto-resume logic inside switchToStreamFromWidget.
        pendingWidgetSwitchWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            Task { @MainActor in
                self.setIsSwitchingStream(true)
                defer { self.setIsSwitchingStream(false) }

                guard let targetStream = DirectStreamingPlayer.availableStreams.first(where: { $0.languageCode == languageCode }),
                      let targetIndex = DirectStreamingPlayer.availableStreams.firstIndex(where: { $0.languageCode == languageCode }) else {
                    #if DEBUG
                    print("[RadioPlayerCoordinator] Widget switch: target stream not found for \(languageCode)")
                    #endif
                    // Still clear the action to avoid it sticking around.
                    SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
                    return
                }

                await self.switchToStreamFromWidget(to: targetStream, index: targetIndex, actionId: actionId)
            }
        }

        pendingWidgetSwitchWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    /// Canonical (silent) stream-switch orchestration for widget and Live Activity reconciliation.
    ///
    /// This is the non-tuning, non-animating counterpart to `completeStreamSwitch`. It is the
    /// single place that reconciles an optimistic widget/LA language choice (signaled via
    /// `signalWidgetSwitchAction` + Darwin "switch" pending) with the authoritative engine
    /// and main-app visual/intent state.
    ///
    /// Responsibilities (executed in order):
    /// 1. Read `currentPlaybackIntent` once at entry and derive `shouldResumeAfterSwitch`
    ///    (`isActivePlaybackIntent`).
    /// 2. If resuming: `resetToPrePlayForNewStream` + Connecting UI **before** engine teardown
    ///    so Live Activity never stays `.playing` mid silent stop (symmetric with
    ///    `completeStreamSwitch`). If **paused**: ``stampStreamSwitchDestinationLanguage`` +
    ///    awaited destination snapshot + media-surface refresh **without** `.prePlay` hold
    ///    (sticky `.userPaused` chrome; language advances immediately).
    /// 3. Engine preparation exclusively via `DirectStreamingPlayer.switchToStream(_:)`
    ///    (the SSOT: model update, transient reset, awaited stop for lang change, counter reset).
    /// 4. Mirror selection + language snapshot + LA language mirror + media-surface refresh.
    /// 5. If `!shouldResumeAfterSwitch`: clear soft-pause stash, force `.userPaused` visual,
    ///    clear destination stamp if not holding, announce, clear the `actionId`, and return
    ///    (no playback started).
    /// 6. If resuming: `SharedPlayerManager.play()` (hold already active). Stream failure leaves
    ///    intent active (`.shouldBePlaying` / `.sleepTimer`), so this path auto-resumes without
    ///    an extra play tap.
    /// 7. Announce + clear pending `actionId`.
    ///
    /// **Direct `play()` rule (authoritative):** The call to `play()` in the resume branch is
    /// the *internal continuation in the active-intent resume branch* (after `isActivePlaybackIntent`
    /// was already true). It is one of the four explicitly permitted direct `play()` sites
    /// (see `userRequestedPlay` Precondition).
    /// All *explicit* user play/resume requests (widget play pending, toggle buttons, remote
    /// commands, Siri Play, LA start, security retry, etc.) must go through `userRequestedPlay()`.
    /// This site must **not** be changed to `userRequestedPlay()`; doing so would blur the
    /// distinction, risk overriding concurrent pause intents, and break symmetry with
    /// `completeStreamSwitch`. See the Precondition on `userRequestedPlay()` (permitted
    /// direct `play()` cases) and the matching rule on `completeStreamSwitch`.
    ///
    /// - Parameters:
    ///   - stream: Target stream chosen by the widget/LA action.
    ///   - index: Index of `stream` in `DirectStreamingPlayer.availableStreams` (used for
    ///            selector + background sync only).
    ///   - actionId: The pending action identifier from the widget signal (used for dedup
    ///               and to clear the transient command after reconciliation).
    ///
    /// - Precondition: Caller must have set `streamingPlayer.isSwitchingStream = true`
    ///   for the duration (this method does not own the flag). Must run on the @MainActor.
    /// - Postcondition: Engine model and UI selection reflect `stream`. If the pre-switch
    ///   intent was active, playback proceeds (or is initiated) for the new stream; otherwise
    ///   the selection is left in `.userPaused`. The `actionId` has been cleared.
    ///
    /// - Important: This method **never** plays the tuning sound and never animates the
    ///   needle. Those effects are owned exclusively by `completeStreamSwitch`.
    /// - Important: Widget switch semantics deliberately differ from Siri
    ///   `SwitchToLanguageIntent`: the latter always forces playback via `userRequestedPlay()`
    ///   after its switch (imperative "play in X"). Widget reconciliation preserves the
    ///   paused/playing choice that was current at the moment the widget action was issued.
    ///
    /// - SeeAlso: `completeStreamSwitch`,
    ///   `handleWidgetSwitchToLanguage`,
    ///   `DirectStreamingPlayer.switchToStream`,
    ///   ``SharedPlayerManager/play()``,
    ///   ``SharedPlayerManager/userRequestedPlay()``,
    ///   ``SharedPlayerManager/resetToPrePlayForNewStream(preserveActiveSleepTimer:)``,
    ///   ``SharedPlayerManager/stampStreamSwitchDestinationLanguage(_:)``,
    ///   ``SharedPlayerManager/clearStreamSwitchDestinationLanguageIfNotHolding()``,
    ///   ``SharedPlayerManager/markPlaybackStoppedByStreamFailure(_:)``,
    ///   ``SharedPlayerManager/currentPlaybackIntent``,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§6.12, §10),
    ///   CODING_AGENT.md (Single Source of Truth Principles),
    ///   <doc:Architecture>.
    ///
    /// AGENT NOTE: switchToStreamFromWidget + completeStreamSwitch are the two canonical
    /// stream-choice orchestrators. Both use the identical pattern for the resume case:
    /// read isActivePlaybackIntent → guard → resetToPrePlayForNewStream (if resuming) →
    /// direct `play()`. This is *not* an explicit request site. Update this `///`, the
    /// parallel doc on `completeStreamSwitch`, the architecture block comment, the
    /// userRequestedPlay Precondition, and the resurrection table together on any change.
    /// The justification for keeping the direct call (resurrection guards, race behavior,
    /// explicit-vs-continuation distinction, symmetry with completeStreamSwitch) lives in
    /// these `///` headers and the Precondition.
    private func switchToStreamFromWidget(to stream: DirectStreamingPlayer.Stream, index: Int, actionId: String) async {
        let playbackIntent = await SharedPlayerManager.shared.currentPlaybackIntent
        let shouldResumeAfterSwitch = playbackIntent.isActivePlaybackIntent

        // Destination language **before** silent engine teardown so LA / snapshot never lag on
        // the prior stream for one content push (symmetric with completeStreamSwitch).
        // Active intent: Connecting hold + destination. Sticky pause: destination stamp only
        // (keep `.userPaused` chrome; never auto-resume).
        if shouldResumeAfterSwitch {
            await SharedPlayerManager.shared.resetToPrePlayForNewStream(
                preserveActiveSleepTimer: playbackIntent == .sleepTimer,
                connectingLanguageCode: stream.languageCode
            )
            updateUI(for: .prePlay)
        } else {
            await SharedPlayerManager.shared.stampStreamSwitchDestinationLanguage(stream.languageCode)
            await updateUserDefaultsLanguage(stream.languageCode)
            #if LUTHERAN_MAIN_APP
            await SharedPlayerManager.shared.refreshAllMediaSurfaces(liveActivity: .updateIfActive)
            #endif
        }

        // Engine prep via the SSOT. Replaces all prior manual setSelected + reset + stop sites
        // on the widget path.
        await streamingPlayer.switchToStream(stream)

        selectedStreamIndex = index
        backgroundImageController.update(for: stream)
        // Session snapshot language after engine model prep (destination already stamped when
        // paused; hold-time destination when resuming). Must complete before media-surface
        // refresh / any saveCurrentState so destination is not clobbered by a re-resolve from
        // a lagging preferred/snapshot.
        await updateUserDefaultsLanguage(stream.languageCode)
        SharedPlayerManager.persistLiveActivityLanguageMirror(stream.languageCode)
        #if LUTHERAN_MAIN_APP
        await SharedPlayerManager.shared.refreshAllMediaSurfaces(liveActivity: .updateIfActive)
        #endif

        viewModel?.selectedStreamIndex = index // migrated from // languageSelectorView (SwiftUI uses VM) .setSelectedIndex(index, animated: true, caller: "widgetSwitch")

        guard shouldResumeAfterSwitch else {
            #if DEBUG
            print("[RadioPlayerCoordinator] [Widget Switch] Blocked — userPaused, no auto-resume")
            #endif
            await SharedPlayerManager.shared.clearSoftPauseMetadataStashForLanguageChange()
            viewModel?.selectedStreamIndex = index // migrated from // languageSelectorView (SwiftUI uses VM) .setSelectedIndex(index, caller: "widgetSwitch-paused")
            updateUI(for: .userPaused)
            // Destination fully stamped (snapshot + mirror + surfaces); drop stamp without hold.
            await SharedPlayerManager.shared.clearStreamSwitchDestinationLanguageIfNotHolding()
            announceSwitchedToLanguage(stream)
            SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
            return
        }

        #if DEBUG
        print("[RadioPlayerCoordinator] ▶ [Widget Switch] Starting new stream using SharedPlayerManager.play() — main app path")
        #endif

        // Direct `play()` after prePlay hold + engine prep. Permitted internal continuation
        // when playback intent was already active — do not route to `userRequestedPlay()`.
        await SharedPlayerManager.shared.play()

        #if DEBUG
        print("[RadioPlayerCoordinator] Widget switch: SharedPlayerManager.play() succeeded")
        print("[RadioPlayerCoordinator] Widget switch completed (authoritative save covered by play())")
        #endif

        announceSwitchedToLanguage(stream)
        SharedPlayerManager.shared.clearPendingAction(actionId: actionId)
    }

    // MARK: - Main-app flag-tap language selection

    /// Language-selector entry: optimistic prePlay when auto-play, debounce, then ``completeStreamSwitch``.
    ///
    /// Wired from `PlayerViewModel.onLanguageSelected` in ``wireAndInitialSetup()``.
    ///
    /// - Parameter newIndex: Index into `DirectStreamingPlayer.availableStreams`.
    /// - SeeAlso: ``completeStreamSwitch(stream:index:)``, `LanguageSelectorView`.
    func handleLanguageSelection(at newIndex: Int) {
        // isDeallocating guard stays in host (VC) for now; coordinator is torn down with VC.
        #if DEBUG
        print("[RadioPlayerCoordinator] handleLanguageSelection called for index \(newIndex)")
        #endif

        selectedStreamIndex = newIndex
        Task { @MainActor [weak self] in
            guard let self else { return }
            let vs = await SharedPlayerManager.shared.currentVisualState
            if vs.shouldAutoPlayOrResume {
                let intent = await SharedPlayerManager.shared.currentPlaybackIntent
                let streams = DirectStreamingPlayer.availableStreams
                let connectingLanguage: String? =
                    streams.indices.contains(newIndex) ? streams[newIndex].languageCode : nil
                await SharedPlayerManager.shared.resetToPrePlayForNewStream(
                    preserveActiveSleepTimer: intent == .sleepTimer,
                    connectingLanguageCode: connectingLanguage
                )
                self.updateUI(for: .prePlay)
            } else {
                viewModel?.selectedStreamIndex = newIndex
            }
        }

        let now = Date()
        if let lastTime = lastStreamSwitchTime, now.timeIntervalSince(lastTime) < streamSwitchDebounceInterval {
            #if DEBUG
            print("[RadioPlayerCoordinator] handleLanguageSelection: Debouncing stream switch, time since last: \(now.timeIntervalSince(lastTime))s")
            #endif
            return
        }
        lastStreamSwitchTime = now

        streamSwitchWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let stream = DirectStreamingPlayer.availableStreams[newIndex]
            self.backgroundImageController.scheduleDeferredForStreamSwitch(stream)

            if self.isTuningSoundPlaying {
                #if DEBUG
                print("[RadioPlayerCoordinator] handleLanguageSelection: Waiting for tuning sound to complete")
                #endif
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self = self else { return }
                    self.completeStreamSwitch(stream: stream, index: newIndex)
                }
            } else {
                self.completeStreamSwitch(stream: stream, index: newIndex)
            }
        }
        streamSwitchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    /// Updates the shared language for widget/Live Activity consumption and persists
    /// a combined (currentVisualState + language) snapshot.
    ///
    /// - Parameter languageCode: The target stream language (e.g. "fi", "de").
    ///
    /// This is called on every user- or widget-driven language change (completeStreamSwitch,
    /// switchToStreamFromWidget, handleSwitchToLanguage, and early cold-launch seeding).
    ///
    /// **Why the visual must be preserved (not forced to .prePlay):**
    /// When the user changes language while paused (`.userPaused` visual + sticky intent),
    /// the widget must continue to display the grey paused state for the *new* language.
    /// The subsequent widget "play" tap then correctly routes through `userRequestedPlay()`
    /// (clearing the lock and using snapshot alignment in `setUserIntentToPlay`).
    /// Hard-coding `.prePlay` here used to inject the wrong visual into timelines and could
    /// race the snapshot write, producing the exact "widget pause → language change → resume"
    /// misbehavior on device/TestFlight (while simulator masked the timing).
    ///
    /// The authoritative write goes through `saveCombinedWidgetState` (which writes
    /// `PersistedWidgetState` with the actor's `currentVisualState` + the supplied language).
    /// We refresh *after* that persist (inside the Task) using the real visual captured
    /// at decision time. `isLanguageChange` is treated as urgent by `performActualSave`
    /// when full saves occur.
    ///
    /// - Important: Never hard-code visual state here. Always derive from
    ///   `SharedPlayerManager.shared.currentVisualState` (or the caller's knowledge of
    ///   whether we are in a resume vs. paused switch).
    ///
    /// - SeeAlso: ``completeStreamSwitch(stream:index:)``, ``switchToStreamFromWidget(to:index:actionId:)``,
    ///   ``SharedPlayerManager/saveCombinedWidgetState(language:)``,
    ///   ``SharedPlayerManager/setUserIntentToPlay()`` (the snapshot language alignment),
    ///   ``SharedPlayerManager/loadPersistedVisualStateDirect()``,
    ///   ``WidgetRefreshManager/refreshIfNeeded(visualState:currentLanguage:hasError:immediate:)``,
    ///   `PersistedWidgetState`, CODING_AGENT.md (Single Source of Truth Principles),
    ///   SharedPlayerManager.swift (handleWidgetSwitch + "pause on widget → language switch" contract).
    /// Awaits destination language into the session snapshot after engine stream prep.
    ///
    /// **Ordering invariant:** Callers on stream-switch paths **must** `await` this before
    /// ``refreshAllMediaSurfaces``, ``saveCurrentState``, or other work that can re-resolve and
    /// persist language. A fire-and-forget Task used to race the actor: DEBUG logged the
    /// destination code immediately, then a concurrent ``saveCurrentState()`` re-resolved from a
    /// still-lagging preferred/snapshot and wrote the **prior** language last (device-visible
    /// especially on paused switches where Connecting hold does not supply
    /// `connectingLanguageCode`).
    ///
    /// Liveness uses ``SharedPlayerManager/bumpWidgetLivenessTimestamp(policy:minInterval:)`` so the
    /// home-widget privacy gate suppresses `lastUpdateTime` when no Lutheran widgets are configured
    /// (and after privacy clear forces the gate closed). Snapshot persistence remains gated inside
    /// ``SharedPlayerManager/saveCombinedWidgetState(language:)``.
    ///
    /// `saveCombinedWidgetState` persists **current** visual state with the explicit destination
    /// language (e.g. sticky `.userPaused` + new code) so pause → language change → resume keeps
    /// correct chrome and stream alignment via ``loadPersistedVisualStateDirect()`` /
    /// ``setUserIntentToPlay()``.
    ///
    /// Mutation path: language snapshot emit → ``.persistedWidgetStateDidUpdate`` → Tier 2
    /// observer. Imperative ``refreshIfNeeded`` is not used here (language urgency lives in
    /// ``WidgetRefreshManager``).
    ///
    /// - Parameter languageCode: Destination stream language code to persist when the privacy gate allows.
    /// - Postcondition: When the privacy gate allows, the in-process session snapshot language is
    ///   `languageCode` before this method returns (actor hop completed).
    /// - SeeAlso: ``SharedPlayerManager/bumpWidgetLivenessTimestamp(policy:minInterval:)``,
    ///   ``SharedPlayerManager/WidgetLivenessWritePolicy``,
    ///   ``SharedPlayerManager/saveCombinedWidgetState(language:)``,
    ///   ``SharedPlayerManager/saveCurrentState()``,
    ///   ``SharedPlayerManager/clearHomeWidgetLivenessAndInstantFeedbackResiduals()``,
    ///   ``completeStreamSwitch(stream:index:)``, ``switchToStreamFromWidget(to:index:actionId:)``,
    ///   CODING_AGENT.md (Single Source of Truth Principles).
    func updateUserDefaultsLanguage(_ languageCode: String) async {
        // Privacy-gated liveness only — never write lastUpdateTime raw (residual after clear / no widgets).
        SharedPlayerManager.bumpWidgetLivenessTimestamp(policy: .immediate)

        // Await the actor write: destination language must land before subsequent saves re-resolve.
        // Never detach a Task here as the sole writer of switch-path destination language.
        await SharedPlayerManager.shared.saveCombinedWidgetState(language: languageCode)

        #if DEBUG
        print("[RadioPlayerCoordinator] MAIN APP: Updated UserDefaults language to: \(languageCode)")
        #endif
    }

    /// Canonical main-app stream-switch orchestration for flag taps in the language selector.
    ///
    /// This is the full-experience counterpart to the silent `switchToStreamFromWidget`.
    /// It is the single owner of everything that happens when the user taps a language
    /// flag while the main UI is visible (optimistic prePlay, tuning sound, needle animation,
    /// intent-conditional continuation, Now Playing updates).
    ///
    /// Responsibilities (executed in order inside the debounced Task):
    /// 1. Snapshot intent; when resuming, establish `resetToPrePlayForNewStream` hold +
    ///    Connecting chrome **before** engine teardown (may already be set by
    ///    `handleLanguageSelection`). When paused, ``stampStreamSwitchDestinationLanguage`` +
    ///    awaited destination snapshot + media refresh **without** `.prePlay` hold.
    /// 2. Engine prep via `DirectStreamingPlayer.switchToStream` (SSOT silent stop + model).
    /// 3. **Awaited** language snapshot + Live Activity language mirror + media-surface refresh
    ///    (visual is already Connecting or sticky pause — never `.playing` mid-teardown;
    ///    destination language must land before refresh/save re-resolve).
    /// 4. If not resuming: clear soft-pause metadata, force `.userPaused` UI, clear destination
    ///    stamp if not holding, announce, return.
    /// 5. If resuming: optional tuning sound + needle animation, second guard,
    ///    conditional redundant-hold skip, then `SharedPlayerManager.play()`.
    /// 6. Final announce.
    ///
    /// **Direct `play()` rule (authoritative):** Inside the active-intent resume branch we
    /// call `play()` directly. This is internal continuation after a prior explicit action
    /// (or the initial launch) established an active playback intent (`isActivePlaybackIntent`).
    /// It is deliberately *not* routed through `userRequestedPlay()`. The same rule and
    /// justification apply to the resume branch of `switchToStreamFromWidget`. See the full
    /// rule in the Precondition on `userRequestedPlay()` and the matching note on
    /// `switchToStreamFromWidget`.
    ///
    /// - Parameters:
    ///   - stream: The target `Stream` chosen by the user tap.
    ///   - index: Index in `DirectStreamingPlayer.availableStreams` (drives selector
    ///            final position and background controller).
    ///
    /// - Important: Widget and Live Activity reconciliation paths *must not* call this
    ///   method. They go through `handleWidgetSwitchToLanguage` → `switchToStreamFromWidget`
    ///   (no tuning, no needle, different optimistic timing).
    /// - Important: External Siri / shortcut / deep-link switch uses `handleSwitchToLanguage`
    ///   (kept on a lighter attach style) which ends by calling through to `userRequestedPlay()`
    ///   (because a Siri "switch to X" is treated as an imperative play request).
    ///
    /// - SeeAlso: `handleLanguageSelection`,
    ///   `switchToStreamFromWidget(to:index:actionId:)`,
    ///   `handleWidgetSwitchToLanguage`,
    ///   `handleSwitchToLanguage`,
    ///   `DirectStreamingPlayer.switchToStream`,
    ///   ``SharedPlayerManager/play()``,
    ///   ``SharedPlayerManager/userRequestedPlay()``,
    ///   ``SharedPlayerManager/resetToPrePlayForNewStream(preserveActiveSleepTimer:)``,
    ///   ``SharedPlayerManager/stampStreamSwitchDestinationLanguage(_:)``,
    ///   ``SharedPlayerManager/clearStreamSwitchDestinationLanguageIfNotHolding()``,
    ///   ``SharedPlayerManager/currentPlaybackIntent``,
    ///   CODING_AGENT.md (Single Source of Truth Principles + "Cross-target shared source files"),
    ///   <doc:Architecture>.
    ///
    /// AGENT NOTE: completeStreamSwitch and switchToStreamFromWidget are a matched pair of
    /// canonicals. They must continue to use the same pattern for active-intent playback
    /// continuation (direct `play()` after the guard + reset). Changing one without the other,
    /// or routing either resume site to `userRequestedPlay()`, would violate the designation.
    /// Keep the "update together" set in sync: these two `///` docs + architecture block +
    /// userRequestedPlay Precondition + resurrection table.
    private func completeStreamSwitch(stream: DirectStreamingPlayer.Stream, index: Int) {
        self.selectedStreamIndex = index
        saveStateForWidget()

        self.lastStreamSwitchTime = Date()

        streamSwitchTask?.cancel()
        streamSwitchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }

            let visualState = await SharedPlayerManager.shared.currentVisualState
            let playbackIntent = await SharedPlayerManager.shared.currentPlaybackIntent

            #if DEBUG
            print("[RadioPlayerCoordinator] completeStreamSwitch started – currentVisualState = \(visualState), playbackIntent = \(playbackIntent), stream = \(stream.languageCode)")
            #endif

            let shouldResumeAfterSwitch = playbackIntent.isActivePlaybackIntent

            // Destination language **before** silent engine teardown so Live Activity / Now
            // Playing never advertise prior-language chrome mid switch. Active intent:
            // Connecting hold + destination (`handleLanguageSelection` may already hold).
            // Sticky pause: destination stamp only — keep `.userPaused`, no auto-resume.
            if shouldResumeAfterSwitch {
                if await SharedPlayerManager.shared.isStreamSwitchPrePlayHoldActive {
                    #if DEBUG
                    print("[RadioPlayerCoordinator] [completeStreamSwitch] prePlay hold already active before engine prep")
                    #endif
                } else {
                    await SharedPlayerManager.shared.resetToPrePlayForNewStream(
                        preserveActiveSleepTimer: playbackIntent == .sleepTimer,
                        connectingLanguageCode: stream.languageCode
                    )
                }
                self.updateUI(for: .prePlay)
            } else {
                await SharedPlayerManager.shared.stampStreamSwitchDestinationLanguage(stream.languageCode)
                await updateUserDefaultsLanguage(stream.languageCode)
                #if LUTHERAN_MAIN_APP
                await SharedPlayerManager.shared.refreshAllMediaSurfaces(liveActivity: .updateIfActive)
                #endif
            }

            // Engine preparation is performed via the SSOT for *every* user-initiated
            // stream choice (both the resume/play path and the explicit-paused path).
            // switchToStream guarantees ordering (model first, awaited stop when language
            // changes, fresh counters). Visual is already Connecting when intent is active.
            await streamingPlayer.switchToStream(stream)
            guard !Task.isCancelled else { return }

            // Session snapshot language after model prep (destination already stamped when
            // paused; hold-time destination when resuming). Await destination before
            // refresh/save so concurrent re-resolve cannot write prior code last.
            await updateUserDefaultsLanguage(stream.languageCode)
            SharedPlayerManager.persistLiveActivityLanguageMirror(stream.languageCode)
            #if LUTHERAN_MAIN_APP
            await SharedPlayerManager.shared.refreshAllMediaSurfaces(liveActivity: .updateIfActive)
            #endif

            guard shouldResumeAfterSwitch else {
                #if DEBUG
                print("🚫 [RadioPlayerCoordinator] [completeStreamSwitch] Blocked — userPaused, no auto-resume")
                #endif

                await SharedPlayerManager.shared.clearSoftPauseMetadataStashForLanguageChange()

                self.backgroundImageController.cancelPendingDeferral()
                self.backgroundImageController.update(for: stream)
                self.updateUI(for: .userPaused)
                self.viewModel?.selectedStreamIndex = index
                await SharedPlayerManager.shared.clearStreamSwitchDestinationLanguageIfNotHolding()
                announceSwitchedToLanguage(stream)
                return
            }

            #if DEBUG
            print("[RadioPlayerCoordinator] ▶ [completeStreamSwitch] Allowed resume during stream switch (was playing)")
            #endif

            await playTuningSound(animateNeedleTo: index)
            guard !Task.isCancelled else { return }

            guard shouldResumeAfterSwitch else {
                #if DEBUG
                print("[RadioPlayerCoordinator] [completeStreamSwitch] Blocked play() after tuning sound")
                #endif
                viewModel?.selectedStreamIndex = index // migrated from // languageSelectorView (SwiftUI uses VM) .setSelectedIndex(index, caller: "completeStreamSwitch-blockedPlay")
                return
            }

            #if DEBUG
            print("[RadioPlayerCoordinator] completeStreamSwitch → calling SharedPlayerManager.play() after tuning")
            #endif

            // Direct `play()` here (and the symmetric site in switchToStreamFromWidget) is the
            // permitted internal continuation inside the active-intent resume branch. We reach
            // it only after `isActivePlaybackIntent` was already true. Explicit play requests
            // use `userRequestedPlay()`. See the `///` rule above and the Precondition on
            // `userRequestedPlay()`.
            if await SharedPlayerManager.shared.isStreamSwitchPrePlayHoldActive {
                #if DEBUG
                print("[RadioPlayerCoordinator] [completeStreamSwitch] Skipping redundant resetToPrePlayForNewStream — hold already active")
                #endif
            } else {
                let intent = await SharedPlayerManager.shared.currentPlaybackIntent
                await SharedPlayerManager.shared.resetToPrePlayForNewStream(
                    preserveActiveSleepTimer: intent == .sleepTimer,
                    connectingLanguageCode: stream.languageCode
                )
            }
            updateUI(for: .prePlay)

            await SharedPlayerManager.shared.play()
            guard !Task.isCancelled else { return }
            await Task.yield()

            announceSwitchedToLanguage(stream)

            #if DEBUG
            print("[RadioPlayerCoordinator] completeStreamSwitch: Switched to stream \(stream.language), index=\(index)")
            #endif
        }
    }

    // MARK: - Accessibility (language switch)

    /// Posts a VoiceOver announcement that the stream language has changed.
    ///
    /// Revives the previously stale `"switched_to_language %@"` catalog entry
    /// (introduced for a11y but orphaned during the RadioPlayerCoordinator extraction).
    /// Called from the three canonical language-switch orchestration methods after the
    /// target stream has been applied and the selection UI updated.
    ///
    /// Uses the exact registered key with %@ placeholder + `String(format:)` so the
    /// extractor keeps the entry fresh and all 27 localizations remain active.
    ///
    /// - Parameter stream: The stream that was switched to. Its `.language` property
    ///   already holds the localized human-readable name (e.g. "English", "Suomi").
    /// - SeeAlso: `completeStreamSwitch`, `switchToStreamFromWidget(to:index:actionId:)`,
    ///   `handleSwitchToLanguage`, `DirectStreamingPlayer.Stream.language`
    private func announceSwitchedToLanguage(_ stream: DirectStreamingPlayer.Stream) {
        // SAFETY: UIAccessibility.post is the standard API for VoiceOver announcements.
        // The unsafe marker satisfies SWIFT_STRICT_MEMORY_SAFETY; this is the same
        // pattern used for all other .announcement posts in this file and ViewController.
        let announcement = unsafe String(
            format: String(
                localized: "switched_to_language %@",
                defaultValue: "Switched to %@",
                table: "Localizable",
                comment: "Voiceover announcement announcing the language switch. The placeholder value is replaced with the actual language name."
            ),
            stream.language
        )
        unsafe UIAccessibility.post(notification: .announcement, argument: announcement)
    }
}
