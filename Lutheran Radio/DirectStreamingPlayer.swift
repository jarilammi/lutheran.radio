//
//  DirectStreamingPlayer.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 25.2.2025.
//
//  Public façade for the secure streaming engine (AVPlayer attach, recovery, network path,
//  resource loader, SSL). Domain behavior is file-split — see the isolation map on the class.
//
//  Ownership boundary (do not invert):
//  - This type owns engine runtime: AVPlayer, attach generation, soft silence, stream catalog
//    inputs, server selection, path monitoring for streaming retries, permanent/transient
//    stream errors, validation-state gates that block attach.
//  - SharedPlayerManager owns visual/intent SSOT (PlayerVisualState, PlaybackIntent),
//    PlayerEvent emission, and widget/LA session snapshot writes (saveCurrentState /
//    performActualSave / persistWidgetSnapshot). Engine paths call into the actor; they are
//    not the visual SSOT and do not “always” persist after every engine mutation.
//  - Cellular ternary preference → CellularPermissionManager (migration-only legacy bool).
//  - DNS / certificate / security-model policy → Core/ only.
//
//  Security invariant: all media items via makeSecuredPlayerItem → resource loader →
//  StreamingSessionDelegate → SecurityConfiguration.makeSecureEphemeralConfiguration().
//
//  - SeeAlso: SharedPlayerManager, PlaybackPlayDecision, CellularPermissionManager,
//    DirectStreamingPlayer+StreamCatalog.swift, DirectStreamingPlayer+ServerSelection.swift,
//    DirectStreamingPlayer+NetworkPath.swift, DirectStreamingPlayer+AudioSession.swift,
//    DirectStreamingPlayer+LocalClipPlayer.swift, DirectStreamingPlayer+ThermalProtection.swift,
//    DirectStreamingPlayer+PlaybackControl.swift, DirectStreamingPlayer+SecuredPlayerItem.swift,
//    DirectStreamingPlayer+SystemMediaSession.swift, DirectStreamingPlayer+DeinitHygiene.swift,
//    DirectStreamingPlayer+StatusCallbackDelivery.swift,
//    DirectStreamingPlayer+PeriodicCertificateValidation.swift,
//    DirectStreamingPlayer+PlaybackAttach.swift,
//    DirectStreamingPlayer+PlayerItemRecovery.swift, DirectStreamingPlayer+ResourceLoader.swift,
//    DirectStreamingPlayer+PlayerVisualState.swift, StreamingSessionDelegate.swift,
//    <doc:Architecture>, CODING_AGENT.md.
//

import Foundation
import Security
import CommonCrypto
@unsafe @preconcurrency import AVFoundation
import dnssd
import Network
import Core
import WidgetSurface

// MARK: - Sendable Completion Helpers (Swift 6)
typealias BoolCompletion   = @Sendable (Bool) -> Void
typealias VoidCompletion   = () -> Void
typealias ResultCompletion<T> = @Sendable (Result<T, Error>) -> Void

// MARK: - Delegate Protocol and Status Enum
/// Protocol for delegate callbacks (e.g., UI updates from ViewController).
protocol StreamingPlayerDelegate: AnyObject {
    /// status = semantic state (playing / paused / etc.)
    /// reasonKey = the exact key from Localizable.xcstrings (e.g. "status_playing", "status_paused")
    func onStatusChange(_ status: PlayerStatus, reasonKey: String?)
}

/// - Article: Core Streaming and Privacy Architecture
///
/// `DirectStreamingPlayer` is the secure audio **engine façade**: AVFoundation HTTPS playback with
/// custom resource loading (`StreamingSessionDelegate`), runtime leaf-certificate digest pinning
/// via Core (`CertificateValidator` / `SecurityConfiguration`), and adaptive network retries.
/// Transition-window certificate leniency (device/server time-skew protected) is policy in Core only.
///
/// ## Ownership and single sources of truth (read carefully)
///
/// **Engine owns (this type + domain extensions):**
/// - AVPlayer lifecycle, attach generation, soft silence / soft-pause attach, item recovery
/// - Stream catalog + `urlWithOptimalServer(for:)` server selection
/// - Engine-side flags used for attach and retries (`isPlaying` rate reality, `selectedStream`,
///   `hasPermanentError`, security-validation gate state that blocks media attach)
/// - **Sole** free-running network path monitor (`hasInternetConnection` + publish via
///   `onNetworkPathChange` for host chrome / cellular prompt; no second monitor on VC)
/// - Secured media construction: always `makeSecuredPlayerItem` → resource loader → Core config
///
/// **SharedPlayerManager owns (not this type):**
/// - Visual chrome SSOT (`PlayerVisualState`) and sticky resurrection rules
/// - Playback intent SSOT (`PlaybackIntent` / `currentPlaybackIntent`)
/// - `PlayerEvent` emission and in-process event streams
/// - Authoritative widget / Live Activity session snapshot writes via `saveCurrentState()` →
///   `performActualSave` / privacy-gated `persistWidgetSnapshot`
///
/// **Related pure helpers (not engine storage):** `PlaybackPlayDecision` in WidgetSurface
/// classifies early play gates; the SPM play pipeline consumes it.
///
/// **AGENT NOTE:** Do **not** treat the engine as visual or intent SSOT. Do **not** assume every
/// engine mutation immediately calls `saveCurrentState()`. Persistence is intentional: SPM
/// orchestration paths, selected status/observer edges, and interruption handlers call save when
/// the cross-process snapshot must update; many engine-internal steps do not. Widget optimistic
/// paths use separate instant-feedback / snapshot helpers under privacy write suppression.
///
/// **Cellular preference SSOT:** ternary `cellularDataPermission` via `CellularPermissionManager`
/// on `UserDefaults.standard` (legacy dismiss bool is migration-read only). Not App Group.
///
/// **Security SSOT:** DNS TXT model validation, pinned digests, ATS SPKI pins, and time-skew
/// policy live exclusively under `Core/` (`SecurityModelValidator`, `CertificateValidator`,
/// `SecurityConfiguration`). This façade consumes them; it never redefines them.
///
/// Workflow:
/// 1. **Setup**: Security-model validation (Core) before trusted attach; AVPlayer + custom resource loading.
/// 2. **Playback control**: Public `play`/`stop` and attach pipeline; adaptive retries (path monitor).
/// 3. **Error handling**: Transient vs permanent stream errors; permanent failures feed SPM sticky
///    `.securityLocked` / stop paths rather than inventing a second visual store.
/// 4. **Host chrome**: Status via `StreamingPlayerDelegate` → `RadioPlayerCoordinator.handleStatusChange`;
///    ICY metadata via `onMetadataChange` registered by the coordinator.
/// 5. **Privacy**: No tracking SDKs; minimal network footprint (see excluded features below).
///
/// Shared process access for the main app: `DirectStreamingPlayer.shared`. Cross-process widget
/// state is never written by inventing a parallel SSOT here — always SPM.
///
/// The Lutheran Radio app prioritizes user privacy and security to protect individuals, particularly in regions where religious content consumption may be monitored or restricted. This design ensures safe, anonymous access to Lutheran content without compromising personal data.
///
/// ## Intentionally Excluded Features
/// To safeguard user privacy, the following features are deliberately excluded:
/// - **Microphone Access**:
///   - Never requests microphone permissions.
///   - Prevents potential audio surveillance.
///   - Ensures conversations remain private.
/// - **Camera Access**:
///   - Never requests camera permissions.
///   - Protects visual environment privacy.
///   - Prevents facial recognition or environment scanning.
/// - **Push Notifications**:
///   - No remote notifications sent to devices.
///   - Prevents tracking of user engagement patterns.
///   - Does not expose listening habits to a remote service.
/// - **Location Services**:
///   - Never requests location permissions.
///   - Prevents tracking of listening locations.
///   - Protects geographical privacy.
/// - **User Accounts/Profiles**:
///   - No registration required.
///   - No personal information collected.
///   - Enables fully anonymous usage.
/// - **Analytics/Tracking**:
///   - No usage statistics collected.
///   - No behavioral analysis performed.
///   - No data shared with third parties.
/// - **User Tracking Data Storage**:
///   - No user-identifiable data stored.
///   - No listening history maintained.
///   - No behavioral tracking or usage patterns recorded.
///
/// ## Security Features Implemented
/// - **Encrypted Connections**:
///   - All streaming uses HTTPS/TLS encryption.
///   - App Transport Security (ATS) enforces pinned public keys via `Info.plist` (`NSAppTransportSecurity`).
///   - Runtime SSL certificate validation with hostname verification is handled in `StreamingSessionDelegate`.
/// - **Dynamic Access Control**:
///   - Queries `securitymodels.lutheran.radio` TXT record to validate app authorization.
///   - Supports remote access control without requiring app updates.
///   - Requires the app security model (`dallas`) to be in the authorized list.
/// - **DNSSEC-authenticated name resolution** (iOS 16+ / always on this deployment target):
///   - Streaming, validation HEAD, and server-ping sessions are created with
///     `URLSessionConfiguration.requiresDNSSECValidation = true` (via
///     ``SecurityConfiguration/makeSecureEphemeralConfiguration()``).
///   - Provides authenticated DNS before TLS + runtime certificate pinning.
///   - Lookup failures (including "DNSSEC unavailable from resolver") are transient.
/// - **Privacy-Safe Data Management**:
///   - Streaming runtime state is in-memory on the engine; durable visual chrome is **not**
///     restored from disk across cold launch (memory-only visual policy on `SharedPlayerManager`).
///   - No listening history or user-identifiable analytics.
/// - **Minimal Network Footprint**:
///   - Connects to streaming servers + security model DNS/validation paths required for access control.
///   - No telemetry or third-party reporting endpoints.
/// - **Minimal Anonymous Preferences**:
///   - Cellular data permission is a ternary preference (`ask` / `alwaysAllow` / `sessionAllow`)
///     owned by `CellularPermissionManager` on standard `UserDefaults` — not dual-written with the
///     retired legacy bool (migration-read only when ternary is absent).
///   - Cannot be used for user identification or tracking; removed when the app is deleted.
///
/// ## Why This Matters
/// Religious freedom includes the right to private worship and study. This design ensures users worldwide can access Lutheran content safely, especially in regions where:
/// - Religious content consumption is monitored.
/// - Government surveillance targets faith communities.
/// - Internet activity is logged and analyzed.
/// - Device permissions may be exploited for tracking.
///
/// > **Important:** This is not just about compliance—it’s about protecting user safety and religious freedom globally.
///
/// ## Developer Notes
/// To maintain the app's privacy-first principles, adhere to the following guidelines:
/// - Never implement push notification capabilities.
/// - Never request microphone or camera permissions.
/// - Never integrate analytics or tracking SDKs.
/// - Always use `HTTPS` for network communication.
/// - Never store user-identifiable information.
/// - Evaluate the privacy implications of any new features.
///
/// > **Note:** These restrictions are critical to ensuring user trust and safety in sensitive regions.

/// Share functionality to the LutheranRadioWidget
extension DirectStreamingPlayer {
    static let shared = DirectStreamingPlayer()
}

// Network path types + setup: DirectStreamingPlayer+NetworkPath.swift
// (NetworkPathStatus, NetworkPathUpdate, NetworkPathMonitoring, NWPathMonitorAdapter,
//  setupNetworkMonitoring). Stored flags remain on this class body.

/// Secure streaming engine façade: AVPlayer, attach/recovery, path monitoring, and Core-backed media security.
///
/// Does **not** own visual/intent SSOT, `PlayerEvent` emission, or widget snapshot policy —
/// those belong to ``SharedPlayerManager``. See the module article and isolation map below.
///
/// - SeeAlso: ``SharedPlayerManager``, `PlaybackPlayDecision`, `CellularPermissionManager`,
///   Core `SecurityConfiguration` / `CertificateValidator` / `SecurityModelValidator`,
///   CODING_AGENT.md (Single Source of Truth Principles), <doc:Architecture>.
final class DirectStreamingPlayer: NSObject, @unchecked Sendable {

    // MARK: - Isolation map (domain split)
    //
    // DirectStreamingPlayer is the public engine façade (`@unchecked Sendable`). Mutable
    // *engine* state is concentrated here; domain behavior lives in extension files.
    // Visual/intent/widget snapshot SSOT is *not* in this map — see SharedPlayerManager.
    //
    // | Domain | File | Responsibility |
    // |--------|------|----------------|
    // | Stream catalog | DirectStreamingPlayer+StreamCatalog.swift | Stream list, language helpers, URL builder inputs |
    // | Server selection | DirectStreamingPlayer+ServerSelection.swift | Server / PingResult, latency, urlWithOptimalServer |
    // | Network path | DirectStreamingPlayer+NetworkPath.swift | Path status types, NWPathMonitorAdapter, setupNetworkMonitoring |
    // | Audio session | DirectStreamingPlayer+AudioSession.swift | Category + async activate/deactivate (configure / setup / deactivate) |
    // | Local clip player | DirectStreamingPlayer+LocalClipPlayer.swift | Tuning/special bundled clip start (`startLocalClipPlayer`); coordinator callers live in `RadioPlayerCoordinator+Tuning` |
    // | Thermal protection | DirectStreamingPlayer+ThermalProtection.swift | Thermal pause/resume + Low Power Mode observation (`setupThermalProtection` / energy) |
    // | Playback control | DirectStreamingPlayer+PlaybackControl.swift | Public play/stop entry (`play`, `createAndStartPlayer`, soft/hard stop paths) |
    // | Secured player item | DirectStreamingPlayer+SecuredPlayerItem.swift | makeSecuredPlayerItem + preparePlayerItem (Core-backed resource loader path) |
    // | System media session | DirectStreamingPlayer+SystemMediaSession.swift | Privacy/factory-reset hard detach (`teardownSystemMediaSession*`) + session deactivate |
    // | Deinit hygiene | DirectStreamingPlayer+DeinitHygiene.swift | `clearCallbacks` + ordered `performDeinitCleanup` (façade `deinit` stays on primary type) |
    // | Status callback delivery | DirectStreamingPlayer+StatusCallbackDelivery.swift | `safeOnStatusChange` / deliver / invoke + transient KVO suppress + metadata hop |
    // | Periodic certificate validation | DirectStreamingPlayer+PeriodicCertificateValidation.swift | `startPeriodicValidation` / `stopPeriodicCertificateValidation` (Core pin HEAD cadence) |
    // | Playback attach | DirectStreamingPlayer+PlaybackAttach.swift | Generation, soft-pause, silence, prepareStreamChoice / attachAndPlay / startPlayback |
    // | Item recovery | DirectStreamingPlayer+PlayerItemRecovery.swift | Startup safety net, early ICY recreate, secured recreate |
    // | Observers | DirectStreamingPlayer+Observers.swift | Player/item KVO, buffer timers |
    // | Metadata | DirectStreamingPlayer+Metadata.swift | ICY StreamTitle push delegate |
    // | Audio interruption | DirectStreamingPlayer+AudioSessionInterruption.swift | AVAudioSession interruption / route |
    // | Resource loader | DirectStreamingPlayer+ResourceLoader.swift | AVAssetResourceLoaderDelegate + Icecast + load timeout |
    // | SSL protection | DirectStreamingPlayer+SSLProtection.swift | Adaptive handshake timers |
    // | Error classification | DirectStreamingPlayer+StreamErrorClassification.swift | StreamErrorType.from |
    // | Visual state bridge | DirectStreamingPlayer+PlayerVisualState.swift | Thin façade → SPM setUserPaused / publish playing (not SSOT storage) |
    // | Widget stub | DirectStreamingPlayer+WidgetStub.swift | Extension-only type surface (`#if !LUTHERAN_MAIN_APP`) |
    //
    // Cross-layer owners (do not re-home into this façade):
    // - PlayerVisualState / PlaybackIntent / PlayerEvent / session snapshots → SharedPlayerManager
    // - Early play gate pure decision → PlaybackPlayDecision (WidgetSurface) + SPM play pipeline
    // - Cellular ternary preference → CellularPermissionManager
    // - DNS TXT / cert digests / ATS SPKI → Core only
    //
    // Security invariant: media items always via makeSecuredPlayerItem → resource loader →
    // StreamingSessionDelegate → SecurityConfiguration.makeSecureEphemeralConfiguration().
    // Never bypass Core certificate / DNS policy from these domain files.
    //
    // Isolation notes (long-term cleanup, not this split):
    // - MainActor owns attach generation, soft-pause, observer setup, recovery gates.
    // - nonisolated stop entry may hop to MainActor for generation bump / teardown guard.
    // - connectionQueue isolates SSL ConnectionInfo dictionary.
    // - @unchecked Sendable documents historical engine sharing; prefer MainActor hops for new work.
    // - Deinit hygiene helpers live in `+DeinitHygiene.swift`; Swift `deinit` itself remains
    //   on this primary type body (language requirement) and only sets `isDeallocating` then
    //   calls ``performDeinitCleanup()``.
    //
    // Network path ownership (single monitor — domain file + façade stored flags):
    // - Setup + types live in `+NetworkPath.swift`; `hasInternetConnection` / `networkMonitor` /
    //   `onNetworkPathChange` / `pathMonitor` remain on this class (stored state).
    // - Host chrome observes via `onNetworkPathChange` — never a second free-running monitor
    //   or HTTP probe timer on VC.
    //
    // Audio session ownership (configure / activate — domain file + façade injection):
    // - Category + activate/deactivate live in `+AudioSession.swift`; injected `audioSession`
    //   and interruption observer flags remain on this class (stored state).
    // - Interruption/route observers: `+AudioSessionInterruption.swift` (not configure).
    // - Never call `setCategory` / `setActive` outside `+AudioSession`. Local clips call
    //   ``configureAudioSessionAsync()`` from `+LocalClipPlayer` only (no direct setActive).
    //
    // Thermal / energy ownership (domain file + façade stored token + computed flag):
    // - Observers + teardown live in `+ThermalProtection.swift`; `thermalObserver` and
    //   ``isLowEfficiencyMode`` remain on this class (stored / computed state).
    // - Visual `.thermalPaused` SSOT remains SharedPlayerManager; this engine only sets it.
    //
    // Playback control ownership (domain file + façade stored attach flags):
    // - Public `play` / `stop` / soft-hard teardown live in `+PlaybackControl.swift`.
    // - Attach generation, soft-pause flags, and `isCurrentlyAttemptingPlayback` remain on
    //   this class (stored state); attach helpers live in `+PlaybackAttach.swift`.
    //
    // Secured player item ownership (domain file + façade buffer constant + player storage):
    // - ``makeSecuredPlayerItem(for:)`` / ``preparePlayerItem(for:)`` live in
    //   `+SecuredPlayerItem.swift` so attach, recovery, and control share one Core-backed path.
    // - Never construct a bare `AVURLAsset` without the resource-loader delegate.
    //
    // System media session ownership (domain file + façade player/item + soft-pause storage):
    // - Privacy / factory-reset hard detach lives in `+SystemMediaSession.swift`
    //   (``teardownSystemMediaSessionSynchronously`` / ``teardownSystemMediaSession``).
    // - Complements SPM ``teardownNowPlayingSession()`` (MPNowPlayingInfoCenter clear only).
    // - Playback soft/hard stop remains in `+PlaybackControl.swift`; do not re-home stop here.
    // - Audio session deactivate is called only via ``deactivateAudioSessionAsync()``.
    //
    // Deinit hygiene ownership (domain file + façade stored teardown flags / maps):
    // - ``clearCallbacks()`` / ``performDeinitCleanup()`` live in `+DeinitHygiene.swift`.
    // - Swift `deinit` remains on this primary type body: set ``isDeallocating`` then call
    //   ``performDeinitCleanup()`` only — never expand cleanup inline again.
    // - Cleanup is fully synchronous; stop / thermal / interruption / SSL handshake /
    //   periodic certificate validation teardown are invoked as helpers, not re-implemented here.
    //
    // Status callback delivery ownership (domain file + façade stored callbacks / dedup):
    // - ``safeOnStatusChange`` / ``deliverStatusChange`` / ``invokeStatusCallbacks`` /
    //   transient suppress gates / ``safeOnMetadataChange`` live in
    //   `+StatusCallbackDelivery.swift`.
    // - Stored `onStatusChange`, `onMetadataChange`, `delegate`, `isInitializing`,
    //   `pendingStatusChanges`, `lastEmittedStatus` remain on this class (stored state).
    // - Visual SSOT + widget persist remain SharedPlayerManager; this domain only invokes
    //   ``saveCurrentState()`` / ``updateNowPlayingInfo()`` after real emissions.
    // - Status *producers* (observers, recovery, path, play/stop, attach) call
    //   ``safeOnStatusChange`` only — never re-implement MainActor hops or suppress gates.
    //
    // Periodic certificate validation ownership (domain file + façade timer storage):
    // - ``startPeriodicValidation()`` / ``stopPeriodicCertificateValidation()`` live in
    //   `+PeriodicCertificateValidation.swift`.
    // - ``certificateValidationTimer`` remains on this class (stored state).
    // - Cadence = ``SecurityConfiguration/certificateValidationCacheDuration`` (not DNS model cache).
    // - Validation policy stays in Core `CertificateValidator`; this engine only schedules + reacts.
    // - SSL handshake timers remain in `+SSLProtection.swift` (distinct domain).

    var isSSLHandshakeComplete = false
    /// Periodic Core pin revalidation timer storage (lifecycle: `+PeriodicCertificateValidation.swift`).
    var certificateValidationTimer: Timer?
    var hasStartedPlaying = false
    /// True while cold launch / stream-switch attach waits for `.readyToPlay` before the first audible kick.
    var isDeferringFirstPlayKick = false
    /// True after the first non-empty ICY StreamTitle on the current attach (cold launch / stream switch).
    // Writable from Metadata / attach recovery domain files (same module).
    var hasReceivedLiveStreamMetadata = false
    
    // MARK: - Audio session stored state
    // Configure/activate: +AudioSession.swift. Interruption observers: +AudioSessionInterruption.swift.
    var interruptionObserver: NSObjectProtocol?
    var routeChangeObserver: NSObjectProtocol?
    var wasPlayingBeforeInterruption = false
    var isHandlingInterruption = false
        
    /// Injectable closure for the current date, used for testing time-dependent logic.
    internal var currentDate: @Sendable () -> Date = { Date() }
    
    // Single declaration (no DEBUG/release duplication) for the few members that historically
    // needed relaxed visibility for test/diagnostic inspection. All other state is now declared once.
    internal var networkMonitor: NetworkPathMonitoring?
    /// Authoritative process reachability flag driven by the engine-owned path monitor.
    ///
    /// Host UI and cold-launch guards must read this (or observe ``onNetworkPathChange``)
    /// rather than maintaining a parallel `hasInternetConnection` on `ViewController`.
    /// - SeeAlso: ``setupNetworkMonitoring()``, ``onNetworkPathChange``
    internal var hasInternetConnection = true
    /// Host chrome observer for path transitions (cellular prompt + SPM reconnect/stop surfaces).
    ///
    /// Published from the **single** engine path monitor so the host never starts a second
    /// `NWPathMonitor` or 5 s HTTP connectivity probe. Parameters:
    /// - `isConnected`: `status == .satisfied` after this update
    /// - `isExpensive`: metered/cellular path for ``CellularPermissionManager`` prompt gates
    /// - `wasConnected`: prior ``hasInternetConnection`` before this update (edge detection)
    ///
    /// Invoked on the main queue. Cleared by the host on teardown. No-op under UITestMode
    /// because ``setupNetworkMonitoring()`` does not start the monitor when `isTesting`.
    ///
    /// - SeeAlso: ViewController path observation, ``CellularPermissionManager``
    var onNetworkPathChange: (@Sendable (_ isConnected: Bool, _ isExpensive: Bool, _ wasConnected: Bool) -> Void)?
    var serverFailureCount: [String: Int] = [:]
    var lastFailedServerName: String?
    /// Active cluster selection used by stream URL construction (see DirectStreamingPlayer+StreamCatalog).
    var currentSelectedServer: Server = servers[0]
    
    /// Track initialization and defer callbacks.
    var isInitializing: Bool = true
    var pendingStatusChanges: [(isPlaying: Bool, reasonKey: String?)] = []
    
    /// Simple last-value dedup for status emissions.
    /// Prevents identical consecutive (isPlaying, reasonKey) tuples from re-driving
    /// the delegate + UI + widget pipeline on every KVO jitter or repeated callback.
    var lastEmittedStatus: (isPlaying: Bool, reasonKey: String?)?
    
    // Lightweight raw KVO dedup trackers (used inside the observer closures)
    var lastObservedTimeControl: AVPlayer.TimeControlStatus?
    var lastObservedItemStatus: AVPlayerItem.Status?
    
    /// True while ``play()`` or ``attachAndPlay(to:context:)`` is crossing async attach boundaries
    /// (security validation, server selection, audio-session activation, secured item attach).
    ///
    /// - Important: User pause during this window must **not** leave a late `playImmediately` audible.
    ///   ``stop(reason:completion:silent:applyUserPauseVisualLock:)`` always advances
    ///   ``playbackAttachGeneration`` and soft-silences the engine; in-flight work re-checks generation
    ///   + ``SharedPlayerManager/canProceedWithPlayback()`` after every significant `await` and discards
    ///   when either fails.
    /// - SeeAlso: ``PlaybackAttachState``, ``beginInFlightPlaybackAttach()``,
    ///   ``shouldContinueInFlightAttach(startedAt:)``,
    ///   ``invalidateInFlightPlaybackAttach()``, ``stopAndWait(reason:silent:applyUserPauseVisualLock:)``,
    ///   `SharedPlayerManager.stop()`, docs/Live-Activity-Stacking-and-Media-Surfaces.md (transport coordination).
    var isCurrentlyAttemptingPlayback = false

    /// Monotonic generation for attach/start work.
    ///
    /// Advanced on every ``stop(reason:completion:silent:applyUserPauseVisualLock:)`` so await-crossing
    /// start paths discard stale attach work after sticky `.userPaused` (or any other stop). Captured at
    /// attach start via ``beginInFlightPlaybackAttach()`` and compared in
    /// ``shouldContinueInFlightAttach(startedAt:)``.
    ///
    /// AGENT NOTE: Single source of truth for "this attach attempt is still valid". Do not reset to 0;
    /// only advance. Pair every post-`await` continue with a generation + intent re-check.
    var playbackAttachGeneration: UInt64 = 0


    // MARK: - Playback attach / recovery / observers (domain files)
    // PlaybackAttachState, prepareStreamChoice, attachAndPlay, startPlayback, generation → +PlaybackAttach
    // Startup safety net, early ICY, recreatePlayerItem → +PlayerItemRecovery
    // KVO observers, buffer timers → +Observers


    
    // MARK: - Thermal / energy stored state
    // Observers + teardown: +ThermalProtection.swift. Visual `.thermalPaused` SSOT: SharedPlayerManager.
    /// Detects if the device is in Low Power Mode to throttle non-essential tasks (e.g., retry intervals) and extend battery life during streaming.
    /// Builds on thermal state handling; queried dynamically in retry/fallback logic.
    /// Reference: iOS ProcessInfo.isLowPowerModeEnabled (available since iOS 9).
    /// - SeeAlso: ``setupEnergyEfficiencyObservation()``, DirectStreamingPlayer+ThermalProtection.swift
    var isLowEfficiencyMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    /// Token for `ProcessInfo.thermalStateDidChangeNotification` (owned by thermal domain setup/teardown).
    var thermalObserver: NSObjectProtocol?
    
    // Public accessors for ViewController
    var lastFailedServer: String? { return lastFailedServerName }
    var selectedServerInfo: Server { return currentSelectedServer }

    // MARK: - Injected Dependencies (construction roots)
    let audioSession: AVAudioSession
    let pathMonitor: NetworkPathMonitoring
    
    // MARK: - Enhanced SSL Protection with Connection Tracking
    /// Per-connection info for SSL handshake protection.
    /// - Note: Migrated from `Timer` to `Task<Void, Never>` for Swift 6 Sendable compliance and better cancellation.
    ///   Invariant: `task` fires once after delay, marks `isHandshakeComplete = true` unless cancelled.
    struct ConnectionInfo: Sendable {
        let id: UUID
        let startTime: Date
        let task: Task<Void, Never>
        var isHandshakeComplete: Bool = false
    }
    
    // Dictionary to track multiple connections
    var activeConnections: [UUID: ConnectionInfo] = [:]
    let connectionQueue = DispatchQueue(label: "ssl.connections", qos: .userInitiated)


    // MARK: - Stream catalog / server selection (domain files)
    // Stream, availableStreams, language helpers → DirectStreamingPlayer+StreamCatalog.swift
    // Server, PingResult, selectOptimalServer, urlWithOptimalServer → DirectStreamingPlayer+ServerSelection.swift
    // Stored selection state stays on the façade (extensions cannot declare stored properties).

    var lastServerSelectionTime: Date?
    let serverSelectionCacheDuration: TimeInterval = 7200 // two hours
    var serverSelectionWorkItem: DispatchWorkItem?
    var retryWorkItem: DispatchWorkItem?
    var fallbackWorkItem: DispatchWorkItem?
    /// Work item for pending playback operations that can be cancelled
    var pendingPlaybackWorkItem: DispatchWorkItem?
    /// Track deallocation state (stop / observer teardown).
    var isDeallocating = false

    // MARK: - Error & Retry State (simple scalars)
    var lastError: Error?
    
    var initialPlaybackRetryCount = 0
    /// Hard cap on secured-item recreates from early-window recovery **and** the startup safety net
    /// for a single attach attempt (cold launch or stream switch). Prevents multi-recreate storms
    /// while progressive ICY items are still loading toward `.readyToPlay`.
    let maxInitialRetries = 2

    /// Wall-clock start of the current secured attach (item prepare / recreate).
    ///
    /// Used only for early-window **stall** patience: progressive live MP3 often spends several
    /// seconds at `AVPlayerItem.Status.unknown` with no tracks yet. That is normal loading, not
    /// a reason to tear down and rebuild the secured item. Hard failures (item `.failed`,
    /// buffer-empty with `AVFoundationErrorDomain`) bypass this grace and recover immediately.
    ///
    /// - SeeAlso: ``earlyAttachLoadingGraceSeconds``, ``shouldAttemptEarlyAttachStallRecovery(item:rate:)``,
    ///   ``attemptEarlyWindowTransientRecovery(reason:allowWhileDeferringFirstPlayKick:)``,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§6, §8).
    @MainActor var currentAttachBeganAt: Date?

    /// Minimum time after attach before "not likely to keep up + rate 0" alone may recreate.
    ///
    /// Long enough for first-byte / Fig ICY settle under typical cellular and post-DNS paths;
    /// short enough that a true dead attach still recovers before multi-second dead air feels stuck.
    /// AGENT NOTE: Single source of truth for loading patience — do not invent a second grace timer
    /// in buffer KVO or the startup safety net.
    let earlyAttachLoadingGraceSeconds: TimeInterval = 4.0

    /// Debounce after the loading grace (or after `.readyToPlay`) before stall recovery fires.
    let earlyAttachStallDebounceSeconds: TimeInterval = 1.5

    /// Whether the current attach is still within its initial per-stream recovery budget.
    ///
    /// True after `resetInitialPlaybackCountersForNewStream()` (called by `switchToStream`
    /// for language changes and cold-launch paths) until either:
    /// - `hasStartedPlaying` becomes true after stable playback, or
    /// - the retry budget is exhausted.
    ///
    /// Used by `RadioPlayerCoordinator` (and internal recovery paths) as a cheap predicate
    /// to suppress user-visible transient failure surfaces ("unavailable", grey pause, alert)
    /// for normal ICY/Fig/AAC decoder noise on fresh items. This is the defensive complement
    /// to ``attemptEarlyWindowTransientRecovery(reason:allowWhileDeferringFirstPlayKick:)`` and
    /// ``handleItemStatusFailure(_:)``.
    ///
    /// - Important: This is **not** a general "is playing" flag. It specifically protects the
    ///   early window documented in `switchToStream` and `resetInitialPlaybackCountersForNewStream`.
    ///
    /// - SeeAlso: `switchToStream(_:)`, `resetInitialPlaybackCountersForNewStream()`,
    ///   `handleItemStatusFailure(_:)`, `recreatePlayerItem()`,
    ///   `RadioPlayerCoordinator.handleStatusChange`,
    ///   docs/cold-launch-streamplay-regression-checklist.md (§6 stream failure switch, §8 observers),
    ///   CODING_AGENT.md (Single Source of Truth + explicit transient modeling)
    var isInInitialRecoveryWindow: Bool {
        !hasStartedPlaying && initialPlaybackRetryCount < maxInitialRetries
    }

    /// At most one `recreatePlayerItem()` body may run at a time (MainActor only).
    var recreateInFlight = false
    /// Coalesces rapid early `timeControlStatus` drops on a fresh ICY item into one recovery action.
    var earlyICYDropRecreateTask: Task<Void, Never>?
    /// Set synchronously at intentional stop; cleared when a new secured `playerItem` is attached.
    /// Prevents stale `timeControlStatus` KVO and debounced recreate tasks from running after teardown.
    @MainActor var isPlaybackTeardownActive = false
    /// User-initiated pause kept the secured `AVPlayerItem` alive for gapless same-stream resume.
    @MainActor var isSoftPaused = false
    /// Language of the secured `AVPlayerItem` currently attached (`nil` after hard teardown).
    @MainActor var attachedItemLanguageCode: String?
    /// Cancellable startup safety-net work (cold launch / stream-switch first attach only).
    var startupSafetyNetWorkItem: DispatchWorkItem?
    /// Preferred forward buffer for secured live items (cold attach, switch, and recreate).
    let preferredLiveForwardBufferDuration: TimeInterval = 15.0
    
    var isPlaying: Bool {
        return (player?.rate ?? 0) > 0 && player?.currentItem?.status == .readyToPlay
    }
    
    // Relaxed visibility in Debug builds only — for test / diagnostic inspection.
    // (See the playerItem/metadataOutput block below for the complete list of intentional visibility differences.)
    #if DEBUG
    var selectedStream: Stream {
        didSet {
            if delegate != nil {
                safeOnMetadataChange(metadata: selectedStream.title)
            }
        }
    }
    #else
    private(set) var selectedStream: Stream {
        didSet {
            if delegate != nil {
                safeOnMetadataChange(metadata: selectedStream.title)
            }
        }
    }
    #endif
    
    // MARK: - Public State Accessors
    var currentPlayerRate: Float {
        return player?.rate ?? 0.0
    }

    var currentItemStatus: AVPlayerItem.Status {
        return player?.currentItem?.status ?? .unknown
    }

    var hasPlayerItem: Bool {
        return player?.currentItem != nil
    }

    var actualPlaybackState: Bool {
        return currentPlayerRate > 0.1 &&
               currentItemStatus == .readyToPlay &&
               hasPlayerItem &&
               !hasPermanentError
    }
    
    var player: AVPlayer?

    // Concurrency queues — declared once to avoid duplicated queue declarations between DEBUG and release builds.
    // These three are always private; they are never exposed for testing or external use.
    let audioQueue = DispatchQueue(label: "radio.lutheran.audio", qos: .userInteractive)
    let sslValidationQueue = DispatchQueue(label: "radio.lutheran.ssl", qos: .userInitiated)
    let networkQueue = DispatchQueue(label: "radio.lutheran.network", qos: .utility)

    // Retained only for the historical "compatibility" comment. All real audio/SSL work uses the queues above.
    // Made private in all configurations (no external usage observed in the codebase).
    let playbackQueue = DispatchQueue(label: "radio.lutheran.playback", qos: .userInteractive)

    // MARK: - Playback Engine (player, queues, observers, resource loaders)
    #if DEBUG
    // Relaxed visibility in Debug builds only — for test / diagnostic inspection of the streaming engine.
    // playerItem and metadataOutput (together with selectedStream above) are the only stored properties
    // that intentionally differ in visibility between DEBUG and release.
    var playerItem: AVPlayerItem?
    var metadataOutput: AVPlayerItemMetadataOutput?
    #else
    var playerItem: AVPlayerItem?
    var metadataOutput: AVPlayerItemMetadataOutput?
    #endif
    var needsImmediateMetadataPush = false   // replaces time heuristic
    
    // MARK: - Queue Priority Management
    
    /// Escalates queue priority when audio operations are blocked
    func executeWithAudioPriority<T>(
        _ operation: @escaping @Sendable () -> T,
        completion: @escaping @Sendable (T) -> Void
    ) {
        if player?.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            // Audio is waiting - escalate to highest priority
            DispatchQueue.global(qos: .userInteractive).async {
                let result = operation()
                DispatchQueue.main.async {
                    completion(result)
                }
            }
        } else {
            // Normal priority
            sslValidationQueue.async {
                let result = operation()
                DispatchQueue.main.async {
                    completion(result)
                }
            }
        }
    }
    
    // Important: All AVPlayer operations must be on main thread
    func executeAudioOperation<T>(
        _ operation: @escaping @Sendable () -> T,
        completion: @escaping @Sendable (T) -> Void
    ) {
        // Always execute AVPlayer operations on main thread
        DispatchQueue.main.async {
            let result = operation()
            completion(result)
        }
    }
    
    var hasPermanentError: Bool = false
    var rateObserver: NSKeyValueObservation?
    var statusObserver: NSKeyValueObservation?
    /// Tracks whether a stream switch is in progress to suppress unnecessary "stopped" status updates.
    /// - Note: Set to `true` by `ViewController` before stopping playback during a stream switch and reset to `false` after playback resumes. Used in `stop` to determine if status updates should be suppressed.
    /// - Access: `internal` to allow coordination with `ViewController` within the module; not intended for external use.
    var isSwitchingStream = false // Track ongoing stream switches
    var timeObserver: Any?
    var timeObserverPlayer: AVPlayer? // Track the player that added the time observer
    var playerItemObservations: [NSKeyValueObservation] = []  // Store all playerItem observations
    var bufferingTimer: Timer?
    var activeResourceLoaders: [AVAssetResourceLoadingRequest: StreamingSessionDelegate] = [:] // Track resource loaders
    
    weak var currentLoadingDelegate: StreamingSessionDelegate?   // weak to avoid retain cycles
    var loadingTimeoutWorkItem: DispatchWorkItem?
    
    var onStatusChange: ((Bool, String) -> Void)?
    var onMetadataChange: ((String?) -> Void)?
    internal var currentMetadata: String?

    // MARK: - Status / metadata callback delivery (see DirectStreamingPlayer+StatusCallbackDelivery.swift)
    // safeOnStatusChange / deliverStatusChange / invokeStatusCallbacks + transient KVO suppress
    // gates + safeOnMetadataChange. Stored callbacks / dedup / init-queue stay on this class.

    weak var delegate: StreamingPlayerDelegate?

    /// Sets the delegate for callbacks (e.g., status updates).
    func setDelegate(_ delegate: StreamingPlayerDelegate?) {
        self.delegate = delegate
    }
    
    public func resetTransientErrors() {
        // Reset transient state in the shared validator
        // (Permanent failures stay permanent until app restart or model rotation)
        Task {
            await SecurityModelValidator.shared.resetTransientState()
        }
        
        // Also clear any local permanent error flag if your UI/playback uses it
        hasPermanentError = false
        
        // Clear dedup state so post-reset status changes are not incorrectly suppressed.
        lastEmittedStatus = nil
        lastObservedTimeControl = nil
        lastObservedItemStatus = nil
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Playback] Requested reset of transient security validation state (NOTE: initialPlaybackRetryCount and hasStartedPlaying are deliberately NOT reset here — use resetInitialPlaybackCountersForNewStream() for user stream switches)")
        #endif
    }

    /// Called on every user-initiated language/stream switch (flag-tap via completeStreamSwitch,
    /// widget via handleWidgetSwitchToLanguage, Siri/shortcut, or any path that ends up
    /// calling `switchToStream`).
    ///
    /// Gives the *new* stream a clean startup attempt budget (retryCount = 0) so that
    /// transient ICY noise or safety-net exhaustion from the *previous* stream cannot
    /// trigger a false-positive status_stream_unavailable (red banner + popup).
    ///
    /// Resets cold-launch / stream-switch recovery counters so each attach gets a fresh budget.
    ///
    /// The budget is observable via `isInInitialRecoveryWindow`, which the coordinator uses to
    /// suppress transient failure UI during the window. Also clears the loading-grace clock so
    /// the next secured item starts a clean patience window.
    ///
    /// AGENT NOTE: Prefer calling `switchToStream(_:)` (or the higher-level coordinator paths)
    /// rather than manually calling the individual reset + stop steps.
    func resetInitialPlaybackCountersForNewStream() {
        initialPlaybackRetryCount = 0
        hasStartedPlaying = false   // defensive; the preceding stop() already does this for most paths
        isDeferringFirstPlayKick = false
        hasReceivedLiveStreamMetadata = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.cancelEarlyICYDropRecreate()
            self.currentAttachBeganAt = nil
        }

        #if DEBUG
        print("[DirectStreamingPlayer] [Playback] resetInitialPlaybackCountersForNewStream — fresh startup budget for stream switch (retryCount reset to 0)")
        #endif
    }

    func isLastErrorPermanent() async -> Bool {
        await SecurityModelValidator.shared.isPermanentlyInvalid
    }
    
    private override init() {
        self.audioSession = .sharedInstance()
        self.pathMonitor = NWPathMonitorAdapter()
        
        // Use the centralized preference-respecting helper (bestInitialLanguageCode).
        // Previously duplicated fragile Locale.current + ?? [0] logic here and in the other init.
        selectedStream = Self.streamForLanguageCode(Self.bestInitialLanguageCode())
        
        // isTesting is now a computed property that delegates live to
        // SharedPlayerManager.isRunningInUITestMode (the SSOT). No assignment needed.
        
        super.init()
        
        // Now async (uses configureAudioSessionAsync under the hood). Fire-and-forget is safe here:
        // activation is non-blocking and any playback paths re-ensure / await as needed.
        Task { @MainActor in
            await setupAudioSession()
        }
        setupNetworkMonitoring()
        
        #if DEBUG
        print("[DirectStreamingPlayer] Player initialized, starting validation")
        #endif
        
        if hasInternetConnection && !isTesting {
            // Eager initial validation is skipped entirely under test (isTesting is sourced from
            // SharedPlayerManager.isRunningInUITestMode, which prefers "-UITestMode").
            // This avoids DNS TXT + security network I/O on every UITest launch before any test code runs.
            // Real validation still occurs for normal app cold launches (via SPM.play and other paths).
            Task { @MainActor in
                let isValid = await SecurityValidationFacade.validate(.eagerWarm)
                
                #if DEBUG
                print("[DirectStreamingPlayer] Initial validation completed: \(isValid)")
                #endif
                
                if isValid {
                    self.safeOnStatusChange(isPlaying: false, reasonKey: "status_connecting")
                } else {
                    let isPermanent = await SecurityValidationFacade.isPermanentlyInvalid()
                    let statusKey = isPermanent ? "status_security_failed" : "status_no_internet"
                    self.safeOnStatusChange(isPlaying: false, reasonKey: statusKey)
                    
                    #if DEBUG
                    print("[DirectStreamingPlayer] Validation failed — permanent? \(isPermanent)")
                    #endif
                }
            }
        }
        // IMPORTANT: Emit *zero* status at init time under test (for the main shared instance
        // created via static let / designated init, used by coordinator/VC/VM).
        // Previous else-if/else here called safeOnStatusChange synchronously, feeding the
        // delegate → widget / Live Activity pipeline and contributing to renderer wake + audio side effects.
        // The hard guard in safeOnStatusChange + this structure ensures no init-time emissions.
        
        // Thermal pause/resume: ``setupThermalProtection()`` in +ThermalProtection.swift
        setupThermalProtection()
        
        // Clear dedup state so the first real post-init status always emits.
        lastEmittedStatus = nil
        lastObservedTimeControl = nil
        lastObservedItemStatus = nil
        
        isInitializing = false
        
        DispatchQueue.main.async {  // Defer to after init returns
            for change in self.pendingStatusChanges {
                // Updated to pass reasonKey (see property change below)
                self.invokeStatusCallbacks(isPlaying: change.isPlaying, reasonKey: change.reasonKey)
            }
            self.pendingStatusChanges = []
            
            // Fire-and-forget the final state save (post-init, no blocking needed)
            Task {
                await SharedPlayerManager.shared.saveCurrentState()
            }
        }
    }
    
    // Network path setup: ``setupNetworkMonitoring()`` lives in
    // DirectStreamingPlayer+NetworkPath.swift (sole free-running monitor ownership).
    // Thermal / energy observers: DirectStreamingPlayer+ThermalProtection.swift
    
    init(audioSession: AVAudioSession = .sharedInstance(), pathMonitor: NetworkPathMonitoring = NWPathMonitorAdapter()) {
        self.audioSession = audioSession
        self.pathMonitor = pathMonitor
        
        // Use the centralized preference-respecting helper (bestInitialLanguageCode).
        // Previously duplicated fragile Locale.current + ?? [0] logic here and in the designated init.
        selectedStream = Self.streamForLanguageCode(Self.bestInitialLanguageCode())
        
        // isTesting is now a computed property that delegates live to
        // SharedPlayerManager.isRunningInUITestMode (the SSOT). No assignment needed.
        
        super.init()
        
        // Now async (uses configureAudioSessionAsync under the hood). Fire-and-forget is safe here:
        // activation is non-blocking and any playback paths re-ensure / await as needed.
        Task { @MainActor in
            await setupAudioSession()
        }
        setupNetworkMonitoring()
        
        // Low Power Mode observation: +ThermalProtection.swift (no immediate playback action)
        setupEnergyEfficiencyObservation()
        
        #if DEBUG
        print("[DirectStreamingPlayer] Player initialized, starting validation")
        #endif
        
        if hasInternetConnection && !isTesting {
            // Eager initial validation is skipped entirely under test (isTesting via SharedPlayerManager.isRunningInUITestMode).
            // Matches the designated init() and prevents real DNS/security I/O + status callbacks
            // during unit tests (MockDirectStreamingPlayer path) and UI tests.
            Task { @MainActor in
                let isValid = await SecurityValidationFacade.validate(.eagerWarm)
                
                #if DEBUG
                print("[DirectStreamingPlayer] Initial validation completed: \(isValid)")
                #endif
                
                if isValid {
                    self.safeOnStatusChange(isPlaying: false, reasonKey: "status_connecting")
                } else {
                    // Optional: show appropriate failure state
                    let isPermanent = await SecurityValidationFacade.isPermanentlyInvalid()
                    let statusKey = isPermanent ? "status_security_failed" : "status_no_internet"
                    self.safeOnStatusChange(
                        isPlaying: false,
                        reasonKey: statusKey
                    )
                }
            }
        }
        // IMPORTANT: No status emission at init time under test mode.
        // Previously an `else if isTesting` / `else` branch called safeOnStatusChange here,
        // which fed the delegate → UI → widget / Live Activity pipeline before any test code ran.
        // We must emit *zero* status from init when isTesting (sourced from the SSOT).
        // The hard guard inside safeOnStatusChange provides defense-in-depth for any other call sites.
    }

    // MARK: - System media session (see DirectStreamingPlayer+SystemMediaSession.swift)
    // Privacy / factory-reset hard detach: teardownSystemMediaSessionSynchronously /
    // teardownSystemMediaSession. Complements SPM teardownNowPlayingSession (metadata only).
    // Audio session deactivate: +AudioSession.swift. Playback stop: +PlaybackControl.swift.

    // Local clip player (tuning / special sounds): DirectStreamingPlayer+LocalClipPlayer.swift
    // Session configure SSOT used by clips: DirectStreamingPlayer+AudioSession.swift

    // MARK: - Periodic certificate validation (see DirectStreamingPlayer+PeriodicCertificateValidation.swift)
    // startPeriodicValidation / stopPeriodicCertificateValidation — Core pin HEAD cadence
    // via CertificateValidator; timer storage (certificateValidationTimer) stays on this class.
    // Distinct from SSL handshake timers in +SSLProtection.swift.

    // MARK: - Playback control (see DirectStreamingPlayer+PlaybackControl.swift)
    // Public play / stop entry surface: play(), createAndStartPlayer(for:attachGeneration:),
    // stop / stopAndWait / performActualStop / stopSynchronously / performStopCleanup.

    // MARK: - Secured player item (see DirectStreamingPlayer+SecuredPlayerItem.swift)
    // makeSecuredPlayerItem(for:) + preparePlayerItem(for:) — sole Core-backed construction
    // path for attach / recovery / control. Never bare AVURLAsset without resource loader.

    // MARK: - Stream choice / attach (see DirectStreamingPlayer+PlaybackAttach.swift)
    // prepareStreamChoice, attachAndPlay, switchToStream, startPlayback, generation, soft-pause.

    func isActuallyPlaying() -> Bool {
        guard let player = self.player else { return false }
        return player.timeControlStatus == .playing && player.rate > 0.0
    }

    /// True after the canonical readyToPlay play kick has started stable audible output.
    @MainActor
    func isPlaybackAttachStable() -> Bool {
        guard let player, let item = player.currentItem else { return false }
        return hasStartedPlaying
            && !isDeferringFirstPlayKick
            && item.status == .readyToPlay
            && player.rate > 0.1
    }
    
    
    func setVolume(_ volume: Float) {
        executeAudioOperation({
            self.player?.volume = volume
            return ()
        }, completion: { _ in })
    }

    // MARK: - Callback / deinit hygiene (see DirectStreamingPlayer+DeinitHygiene.swift)
    // clearCallbacks() + performDeinitCleanup(). Swift `deinit` must stay on this primary
    // type body: set isDeallocating, then call the ordered cleanup helper only.

    deinit {
        isDeallocating = true
        performDeinitCleanup()
    }

}


// Extension to get unique elements from a sequence
extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

