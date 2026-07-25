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
//    DirectStreamingPlayer+PlaybackAttach.swift, DirectStreamingPlayer+PlayerItemRecovery.swift,
//    DirectStreamingPlayer+ResourceLoader.swift, DirectStreamingPlayer+PlayerVisualState.swift,
//    StreamingSessionDelegate.swift, <doc:Architecture>, CODING_AGENT.md.
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
    // - Remaining façade bulk candidates: local clip player, public play/stop cluster,
    //   thermal/energy observers, system media session teardown (peel one domain per session).
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
    // - Never call `setCategory` / `setActive` outside `+AudioSession` (clip helper excepted).

    var isSSLHandshakeComplete = false
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


    
    // MARK: - Energy Efficiency (Battery Optimization)
    /// Detects if the device is in Low Power Mode to throttle non-essential tasks (e.g., retry intervals) and extend battery life during streaming.
    /// Builds on thermal state handling; queried dynamically in retry/fallback logic.
    /// Reference: iOS ProcessInfo.isLowPowerModeEnabled (available since iOS 9).
    var isLowEfficiencyMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
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
    
    // MARK: - Safe callbacks to MainActor (Swift 6 fix)

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

    func setupThermalProtection() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            
            let thermalState = ProcessInfo.processInfo.thermalState
            
            // ── Device overheating ─────────────────────────────────────
            if thermalState == .serious || thermalState == .critical {
                if self.isPlaying {
                    Task { @MainActor in
                        self.stop()                                 // sync
                        await SharedPlayerManager.shared.setVisualState(.thermalPaused)
                    }
                }
                return
            }
            
            // ── Device cooled down again ───────────────────────────────
            if thermalState == .nominal || thermalState == .fair {
                Task { @MainActor in
                    // Must await actor-isolated property (Swift 6 rule)
                    if await SharedPlayerManager.shared.currentVisualState.shouldAutoResumeOnThermalRecovery {
                        // Set visual state *before* play() so UI turns green immediately
                        await SharedPlayerManager.shared.setVisualState(.playing)
                        
                        let success = await self.play()
                        
                        if !success {
                            await SharedPlayerManager.shared.setVisualState(.userPaused)
                        }
                    }
                }
            }
        }
    }
    
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
        
        // Observe Low Power Mode changes to dynamically adjust optimizations
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(energyEfficiencyChanged),
            name: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            object: nil
        )
        
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
    
    /// Handles changes to Low Power Mode state.
    /// No immediate actions here; optimizations (e.g., longer retry intervals) are applied dynamically via isLowEfficiencyMode checks.
    /// This reduces unnecessary work in low-battery scenarios without interrupting core streaming.
    @objc private func energyEfficiencyChanged() {
        // No immediate action needed; the isLowEfficiencyMode property will be queried dynamically in retry/fallback spots
        #if DEBUG
        print("[DirectStreamingPlayer] Low Power Mode changed to: \(isLowEfficiencyMode ? "Enabled" : "Disabled")")
        #endif
    }

    // MARK: - System media session teardown (Now Playing hygiene)
    // Audio session category/activate/deactivate: see DirectStreamingPlayer+AudioSession.swift

    /// Hard-detaches the secured `AVPlayerItem` for privacy / cold-launch factory reset.
    ///
    /// Complements ``SharedPlayerManager/teardownNowPlayingSession()`` which clears
    /// `MPNowPlayingInfoCenter`. Safe when playback is already stopped or during privacy clear.
    ///
    /// - Postcondition: Player paused, current item nil, soft-pause stash cleared.
    /// - SeeAlso: ``teardownSystemMediaSession()``, ``deactivateAudioSessionAsync()``.
    @MainActor
    func teardownSystemMediaSessionSynchronously() {
        guard !isTesting else { return }

        player?.pause()
        player?.rate = 0.0
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
        clearAttachedItemBinding()
        isSoftPaused = false
    }

    /// Full async teardown: synchronous player detach plus audio session deactivation.
    ///
    /// - SeeAlso: ``SharedPlayerManager/teardownNowPlayingSession()``.
    @MainActor
    func teardownSystemMediaSession() async {
        teardownSystemMediaSessionSynchronously()
        _ = await deactivateAudioSessionAsync()
    }

    // MARK: - Local clip player (tuning / special sounds)
    // Session configure SSOT: DirectStreamingPlayer+AudioSession.swift

    /// Configures the shared playback session, then constructs and starts a short local
    /// `AVAudioPlayer` clip **off the main actor**.
    ///
    /// Why this exists: ``configureAudioSessionAsync()`` already activates the session without
    /// blocking the main thread, but `AVAudioPlayer.prepareToPlay()` / `play()` can still
    /// perform an implicit session activation on the **calling** thread. Creating and starting
    /// the clip on a background queue keeps that implicit work off `@MainActor`, eliminating
    /// the SessionCore "UI unresponsiveness if called on the main thread" diagnostic on
    /// cold-launch special tuning and stream-switch tuning paths.
    ///
    /// AGENT NOTE: Single source of truth for local file-clip start after session config.
    /// Do not construct `AVAudioPlayer` + `prepareToPlay`/`play` on `@MainActor` for tuning
    /// delight. Never call `setActive` outside ``configureAudioSessionAsync()`` /
    /// ``deactivateAudioSessionAsync()``.
    ///
    /// - Parameters:
    ///   - url: File URL of a bundled clip (typically WAV).
    ///   - volume: Linear gain applied before start (`0...1`).
    ///   - numberOfLoops: `0` for one-shot (default).
    /// - Returns: The player plus whether `play()` returned true, or `nil` when skipped under
    ///   `isTesting` / widget extension. Callers must retain the player until finish/stop and
    ///   may assign `AVAudioPlayerDelegate` on the main actor after return.
    /// - Throws: Errors from `AVAudioPlayer(contentsOf:)`.
    /// - Precondition: Call from `@MainActor`. The returned player is delivered on the main
    ///   actor for retention and optional delegate assignment.
    /// - Postcondition: When non-`nil` and `didStart == true`, audio is already playing;
    ///   caller owns the strong reference.
    /// - SeeAlso: ``configureAudioSessionAsync()``,
    ///   `RadioPlayerCoordinator.playSpecialTuningSound(completion:)`,
    ///   `RadioPlayerCoordinator.playTuningSound(animateNeedleTo:)`, `TuningSoundCoordinator`.
    @MainActor
    func startLocalClipPlayer(
        contentsOf url: URL,
        volume: Float = 1.0,
        numberOfLoops: Int = 0
    ) async throws -> (player: AVAudioPlayer, didStart: Bool)? {
        if Bundle.main.bundleURL.pathExtension == "appex" {
            return nil
        }
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] startLocalClipPlayer — isTesting, skipping local clip")
            #endif
            return nil
        }

        // Explicit session SSOT first (async / off-main activate). Local clip start below
        // must not re-enter setActive on the main actor.
        _ = await configureAudioSessionAsync()

        let clipURL = url
        let clipVolume = volume
        let clipLoops = numberOfLoops

        // SAFETY: `AVAudioPlayer` is not `Sendable`. Construction, prepare, and play run on a
        // background queue so any implicit session activation stays off the main thread; the
        // instance is then handed back only via the main queue continuation resume (same
        // ownership hand-off pattern as historical main-thread construction, without the
        // main-thread activation cost). A safer typed API is not available from AVFoundation.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(player: AVAudioPlayer, didStart: Bool)?, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let player = try AVAudioPlayer(contentsOf: clipURL)
                    player.volume = clipVolume
                    player.numberOfLoops = clipLoops
                    player.prepareToPlay()
                    let didStart = player.play()
                    DispatchQueue.main.async {
                        continuation.resume(returning: (player: player, didStart: didStart))
                    }
                } catch {
                    DispatchQueue.main.async {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    /// Starts periodic certificate validation against the *currently preferred* URL
    /// (automatically follows server selection changes – if the app switches to a better cluster,
    /// the next validation will check the new cluster’s cert. Since both clusters use the same cert,
    /// this is safe and gives us early detection if one cluster ever diverges).
    ///
    /// Cadence matches ``SecurityConfiguration/certificateValidationCacheDuration`` so proactive
    /// HEAD checks stay aligned with the runtime pin-result cache (not the 1-hour DNS model cache).
    ///
    /// - SeeAlso: ``CertificateValidator/validateServerCertificate(for:)``,
    ///   ``SecurityConfiguration/certificateValidationCacheDuration``
    func startPeriodicValidation() {
        certificateValidationTimer?.invalidate()
        let interval = SecurityConfiguration.current.certificateValidationCacheDuration
        certificateValidationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            
            let urlToValidate = self.selectedStream.url   // always valid, includes current server + security_model
            
            // 2026 concurrency model: fire-and-forget background validation
            // Playback continues optimistically; we only stop if validation later fails.
            Task {
                let isValid = await CertificateValidator.shared.validateServerCertificate(for: urlToValidate)
                
                guard !isValid else { return }
                
                await MainActor.run {
                    self.stop()
                    self.safeOnStatusChange(isPlaying: false, reasonKey: "status_security_failed")  // ← fixed
                }
                
                #if DEBUG
                print("[DirectStreamingPlayer] [Periodic Validation] Certificate validation failed → stopping stream for URL: \(urlToValidate)")
                #endif
            }
        }
    }
    
    // MARK: - Playback Control Methods

    /// Starts or resumes playback after validation and server selection.
    ///
    /// User pause during this method (security validation, server selection, or attach) advances
    /// ``playbackAttachGeneration`` via ``stop(reason:completion:silent:)``. This method re-checks
    /// generation + intent after every significant `await` and discards without audible start.
    ///
    /// - Returns: `true` if playback was successfully *initiated* (item replaced + play() called).
    ///            Note: Actual audio may start slightly later when the item becomes readyToPlay.
    /// - Throws: Only critical unrecoverable errors (rare).
    /// - SeeAlso: ``shouldContinueInFlightAttach(startedAt:)``, ``setStreamAndPlay(to:context:)``,
    ///   ``SharedPlayerManager/canProceedWithPlayback()``.
    @MainActor
    func play() async -> Bool {
        // UI Test isolation (defense-in-depth).
        // Even if a recovery or network-restore path reaches here, never start real playback.
        // Visual state for assertions is driven exclusively through SharedPlayerManager.
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] play() — isTesting, early return (no AVPlayer, no audio session, no network)")
            #endif
            return false
        }

        // === Important guard : Driven by authoritative playback intent ===
        // This is the first execution-engine site wired to `currentPlaybackIntent` via
        // the new `canProceedWithPlayback()` helper. It replaces the prior ad-hoc visualState
        // derivation for this narrow top-level path.
        //
        // Sticky `.userPaused` / `.securityLocked` behavior is preserved exactly (the helper
        // returns false for those states, matching the old `shouldAutoPlayOrResume` rules).
        // This prevents "play-on-pause resurrection" after explicit user pause.
        guard await SharedPlayerManager.shared.canProceedWithPlayback() else {
            #if DEBUG
            print("🚫 [Play Guard] Blocked by playbackIntent = \(await SharedPlayerManager.shared.currentPlaybackIntent)")
            #endif
            safeOnStatusChange(isPlaying: false, reasonKey: "status_paused")   // ← changed
            return false
        }
        
        guard !isCurrentlyAttemptingPlayback else {
            #if DEBUG
            print("[DirectStreamingPlayer] [Playback Guard] Already attempting playback — ignoring duplicate call")
            #endif
            return false
        }
        
        let attachGeneration = beginInFlightPlaybackAttach()
        defer { endInFlightPlaybackAttach() }
        
        safeOnStatusChange(isPlaying: true, reasonKey: "status_connecting")   // ← changed
        SharedPlayerManager.shared.saveFireAndForget()
        
        let isValid = await SecurityValidationFacade.validate(.recoveryValidityCheck)
        // User may have paused (lock screen / Live Activity / Now Playing) during validation.
        guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
            enforceSilenceAfterDiscardedAttach()
            return false
        }
        guard isValid else {
            let isPermanent = await SecurityValidationFacade.isPermanentlyInvalid()
            guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
                enforceSilenceAfterDiscardedAttach()
                return false
            }
            let statusKey = isPermanent ? "status_security_failed" : "status_no_internet"
            safeOnStatusChange(isPlaying: false, reasonKey: statusKey)       // ← changed
            SharedPlayerManager.shared.saveFireAndForget()
            return false
        }
        
        #if DEBUG
        print("[DirectStreamingPlayer] Security validation passed — creating player for \(selectedStream.languageCode)")
        #endif
        
        let streamURL = await urlWithOptimalServer(for: selectedStream)
        guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
            enforceSilenceAfterDiscardedAttach()
            return false
        }
        await createAndStartPlayer(for: streamURL, attachGeneration: attachGeneration)
        guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
            enforceSilenceAfterDiscardedAttach()
            return false
        }

        await SharedPlayerManager.shared.saveCurrentState()
        return true
    }
    
    // MARK: - Main-Actor-Bound Player Creation (Swift 6 safe)

    /// Creates the secured player item and starts AVPlayer when the attach generation is still live.
    ///
    /// - Parameters:
    ///   - url: Stream URL from ``urlWithOptimalServer(for:)``.
    ///   - attachGeneration: Snapshot from ``beginInFlightPlaybackAttach()`` for post-await discard.
    /// - Important: Re-checks generation + intent after audio-session activation so user pause
    ///   during that `await` cannot leave a late `player.play()` audible.
    @MainActor
    func createAndStartPlayer(for url: URL, attachGeneration: UInt64) async {
        // UI Test isolation (defense-in-depth). play() already guards, but this protects
        // any future direct caller of the private helper.
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] createAndStartPlayer — isTesting, no-op")
            #endif
            return
        }

        // === Playback intent + generation guard ===
        // Catches internal/resume paths and races where stop advanced generation while this
        // attach was suspended (security validation, server selection).
        // Sticky .userPaused / .securityLocked / .cleared (privacy clear) behavior preserved exactly.
        guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
            #if DEBUG
            print("🚫 [Deep Play Guard] Blocked — in-flight attach discarded before item create")
            #endif
            enforceSilenceAfterDiscardedAttach()
            return
        }
        
        let playerItem = makeSecuredPlayerItem(for: url)
        self.playerItem = playerItem
        bindAttachedItemToSelectedStream()
        clearPlaybackTeardownGuard()
        
        if self.player == nil {
            self.player = AVPlayer(playerItem: playerItem)
        } else {
            self.player?.replaceCurrentItem(with: playerItem)
        }
        // === Important: Activate the audio session before playback (async, main-thread safe) ===
        let audioSessionOK = await configureAudioSessionAsync()
        #if DEBUG
        if audioSessionOK {
            print("[DirectStreamingPlayer] [MainActor] AVAudioSession activated successfully (.playback)")
        } else {
            print("[DirectStreamingPlayer] [MainActor] Failed to activate AVAudioSession")
        }
        #endif
        // User pause during session activation must not reach player.play().
        guard await shouldContinueInFlightAttach(startedAt: attachGeneration) else {
            enforceSilenceAfterDiscardedAttach()
            return
        }
        // ========================================================
        
        self.player?.play()

        #if DEBUG
        print("[DirectStreamingPlayer] ▶ [MainActor] AVPlayer created + play() called for \(url.lastPathComponent)")
        #endif

        // Do NOT call notifyMainApp here — let SharedPlayerManager do it
    }

    /// Builds a secured live `AVPlayerItem` for lutheran.radio HTTPS streaming.
    ///
    /// Every attach path (cold launch, stream switch, and silent transient recovery) must
    /// create items through this helper so media bytes always load via
    /// `AVAssetResourceLoaderDelegate` → `StreamingSessionDelegate` →
    /// ``SecurityConfiguration/makeSecureEphemeralConfiguration()`` (DNSSEC + runtime
    /// certificate digest validation). A bare `AVURLAsset(url:)` without the resource-loader
    /// delegate would bypass that pipeline.
    ///
    /// - Parameter url: Absolute HTTPS stream URL from ``urlWithOptimalServer(for:)`` (or the
    ///   current item’s URL during in-place recovery).
    /// - Returns: An `AVPlayerItem` with the resource loader wired and live buffer preference set.
    /// - SeeAlso: `preparePlayerItem(for:)`, `recreatePlayerItem()`,
    ///   `resourceLoader(_:shouldWaitForLoadingOfRequestedResource:)`,
    ///   `Core/Configuration/SecurityConfiguration.swift`, CODING_AGENT.md (Core surface area).
    @MainActor
    func makeSecuredPlayerItem(for url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: .main)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = preferredLiveForwardBufferDuration
        return item
    }
    
    @MainActor
    func preparePlayerItem(for url: URL) async {
        let playerItem = makeSecuredPlayerItem(for: url)
        
        if self.player == nil {
            self.player = AVPlayer(playerItem: playerItem)
        } else {
            self.player?.replaceCurrentItem(with: playerItem)
        }
        self.playerItem = playerItem
        bindAttachedItemToSelectedStream()
        clearPlaybackTeardownGuard()
        
        setupPlaybackObservers()
        
        #if DEBUG
        print("[DirectStreamingPlayer] [MainActor] Player item prepared (no auto-play) for \(url.lastPathComponent)")
        #endif
    }

    // MARK: - Playback Setup (MainActor preferred path)

    @MainActor
    func performOptimalServerSelectionAndFullPlaybackSetup() async -> Bool {
        guard !isTesting else {
            #if DEBUG
            print("[DirectStreamingPlayer] performOptimalServerSelectionAndFullPlaybackSetup — isTesting, no-op")
            #endif
            return false
        }

        #if DEBUG
        print("[DirectStreamingPlayer] [Playback Setup] Starting server selection + asset creation")
        #endif

        return await withCheckedContinuation { continuation in
            selectOptimalServer { [weak self] _ in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                let streamURL = self.selectedStream.url

                #if DEBUG
                print("[DirectStreamingPlayer] [Playback Setup] Selected URL: \(streamURL)")
                #endif

                // Everything that touches AVPlayer must run on MainActor
                Task { @MainActor [weak self] in
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }

                    // 1. Audio Session (critical!) — now async to avoid main thread warnings
                    let audioOK = await configureAudioSessionAsync()
                    if !audioOK {
                        #if DEBUG
                        print("[DirectStreamingPlayer] AudioSession failed")
                        #endif
                        continuation.resume(returning: false)
                        return
                    }

                    // 2. Secured asset + resource loader (DNSSEC + cert validation path)
                    let playerItem = self.makeSecuredPlayerItem(for: streamURL)

                    if self.player == nil {
                        self.player = AVPlayer()
                    }

                    self.player?.replaceCurrentItem(with: playerItem)
                    self.playerItem = playerItem
                    self.bindAttachedItemToSelectedStream()
                    self.clearPlaybackTeardownGuard()

                    // 3. Setup observers — BEFORE play()
                    self.setupPlaybackObservers()

                    // 4. Explicit play() — guaranteed on MainActor
                    self.player?.play()

                    #if DEBUG
                    print("[DirectStreamingPlayer] ▶ [Playback Setup] replaceCurrentItem + play() called on main actor")
                    #endif

                    // We consider initiation successful here.
                    continuation.resume(returning: true)
                }
            }
        }
    }


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
    
    // FIXED: Simplified + robust status observer (works with security isolation + MainActor)

    
    /// Stops playback and cleans up resources.
    ///
    /// User pause during connect / first-play / reattach **must** complete: sticky `.userPaused` is
    /// already locked by ``SharedPlayerManager/stop()`` (when that is the entry), generation is advanced
    /// here so in-flight attach discards after its next `await`, and soft pause (or hard teardown)
    /// silences any partially attached player. There is **no** early return that leaves attach free
    /// to call `playImmediately` after paused chrome is shown.
    ///
    /// **Engine-complete ordering:** Soft pause applies `player.pause()` + `rate = 0` (and sets
    /// ``isSoftPaused``) on the MainActor **before** invoking `completion`. Callers that refresh
    /// Now Playing / Live Activity must await that completion (prefer ``stopAndWait(reason:silent:applyUserPauseVisualLock:)``)
    /// so glyphs and system rate cannot flip while audio is still audible.
    ///
    /// **Visual-lock ownership:** When ``SharedPlayerManager/stop()`` already locked sticky
    /// `.userPaused`, pass `applyUserPauseVisualLock: false` so this path does not re-enter
    /// ``markAsUserPaused()`` / ``setUserPaused()`` (avoids a second `refreshAllMediaSurfaces`
    /// storm and a spurious `streamDidPause` after `streamDidStop`). Direct engine stops that do
    /// not go through SPM still use the default `true` and apply the visual lock **after** silence.
    ///
    /// - Parameters:
    ///   - reason: Why we are stopping. This is now the single source of truth for user intent.
    ///             `.userAction` → sticky `.userPaused` when `applyUserPauseVisualLock` is true
    ///             `.streamSwitch`, `.interruption`, `.error` → preserve play intent
    ///   - completion: Optional MainActor handler invoked after soft silence (or hard-teardown
    ///                 scheduling reaches its documented completion points). Always called once.
    ///   - silent: If `true`, skips status updates / UI flicker (exactly as it behaved in recent commits).
    ///   - applyUserPauseVisualLock: When `true` (default) and `reason == .userAction && !silent`,
    ///     applies sticky pause via ``markAsUserPaused()`` **after** engine silence. Pass `false`
    ///     when the caller already owns the sticky lock and will refresh media surfaces once.
    /// - SeeAlso: ``stopAndWait(reason:silent:applyUserPauseVisualLock:)``,
    ///   ``invalidateInFlightPlaybackAttach()``, ``shouldContinueInFlightAttach(startedAt:)``,
    ///   ``shouldAllowAudiblePlaybackKick()``, ``SharedPlayerManager/stop()``,
    ///   docs/Live-Activity-Stacking-and-Media-Surfaces.md (user pause / transport coordination).
    func stop(
        reason: StopReason = .userAction,
        completion: (@MainActor @Sendable () -> Void)? = nil,
        silent: Bool = false,
        applyUserPauseVisualLock: Bool = true
    ) {
        
        #if DEBUG
        print("[DirectStreamingPlayer] FORCE STOPPING ALL PLAYBACK - reason: \(reason), silent: \(silent), applyUserPauseVisualLock: \(applyUserPauseVisualLock), attemptingPlayback: \(isCurrentlyAttemptingPlayback)")
        #endif

        // Always invalidate in-flight attach first. User pause (or any stop) that races security
        // validation / server selection / session activation must win: post-await start paths
        // re-check generation + canProceedWithPlayback and discard without audible output.
        invalidateInFlightPlaybackAttach()

        if isCurrentlyAttemptingPlayback {
            #if DEBUG
            print("[DirectStreamingPlayer] [Stop] User/engine stop during in-flight attach — generation invalidated; soft-silence will run (no early skip)")
            #endif
        }

        let usesSoftPause = reason == .userAction && !silent
        if !usesSoftPause {
            // Activate before any async work so stale KVO / debounced recreate cannot race teardown.
            activatePlaybackTeardownGuardFromStop()
        }
        
        loadingTimeoutWorkItem?.cancel()
        currentLoadingDelegate?.loadingRequest.finishLoading(with: URLError(.cancelled))
        currentLoadingDelegate = nil
        
        removeAudioSessionObservers()
        clearAllSSLProtectionTimers()
        retryWorkItem?.cancel()
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        pendingPlaybackWorkItem?.cancel()
        pendingPlaybackWorkItem = nil
        
        // Soft silence first, then optional sticky visual lock. Outer `completion` fires only after
        // engine silence so SPM can refresh media surfaces without "paused chrome + audible stream".
        // Soft silence is applied on this MainActor task (no nested CheckedContinuation resume on the
        // same stack). Hard teardown still uses a continuation bridged from audioQueue → main.
        Task { @MainActor [weak self, reason, silent, applyUserPauseVisualLock, completion] in
            guard let self else {
                completion?()
                return
            }

            await self.performActualStop(reason: reason, silent: silent)

            // .streamSwitch / .interruption / .error intentionally skip markAsUserPaused().
            // SharedPlayerManager.stop already owns sticky lock + single surface refresh — skip here.
            if applyUserPauseVisualLock && reason == .userAction && !silent {
                await self.markAsUserPaused()
                #if DEBUG
                print("[DirectStreamingPlayer] markAsUserPaused() after soft silence – visualState set to .userPaused")
                #endif
            }

            // Silent stops (privacy clear, stream-switch teardown) must not re-persist a snapshot
            // after ``SharedPlayerManager/clearAllLocalState()`` has removed it.
            if !silent {
                await SharedPlayerManager.shared.saveCurrentState()
            }

            completion?()
        }
    }

    /// Awaits engine stop completion (soft silence or hard-teardown completion).
    ///
    /// Prefer this over fire-and-forget ``stop(reason:completion:silent:applyUserPauseVisualLock:)``
    /// whenever the caller will update Now Playing / Live Activity or treat the stop as
    /// engine-complete. Soft pause guarantees `player.rate == 0` and ``isSoftPaused`` before return.
    ///
    /// - Parameters:
    ///   - reason: Stop reason (see ``stop(reason:completion:silent:applyUserPauseVisualLock:)``).
    ///   - silent: Skips status flicker when `true`.
    ///   - applyUserPauseVisualLock: Pass `false` when ``SharedPlayerManager/stop()`` already
    ///     locked sticky `.userPaused` and will perform the single media-surface refresh.
    /// - SeeAlso: ``stop(reason:completion:silent:applyUserPauseVisualLock:)``,
    ///   ``SharedPlayerManager/stop()``, docs/Live-Activity-Stacking-and-Media-Surfaces.md,
    ///   ``MediaTransportLatencyTimeline`` (DEBUG soft-silence milestone).
    func stopAndWait(
        reason: StopReason = .userAction,
        silent: Bool = false,
        applyUserPauseVisualLock: Bool = true
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stop(
                reason: reason,
                completion: { continuation.resume() },
                silent: silent,
                applyUserPauseVisualLock: applyUserPauseVisualLock
            )
        }
        #if DEBUG
        // Engine-complete: soft pause has rate 0 / hard path finished before this resumes.
        MediaTransportLatencyTimeline.mark(
            .softSilenceComplete,
            detail: "reason=\(reason) silent=\(silent) applyVisualLock=\(applyUserPauseVisualLock)"
        )
        #endif
    }

    /// Performs the actual stop operation (MainActor entry from ``stop``’s isolation task).
    ///
    /// Soft pause (user action, non-silent) applies silence on the MainActor **before** return —
    /// no intermediate `audioQueue` hop — so awaiters observe a silent engine.
    /// Hard teardown schedules cleanup on `audioQueue` and resumes only after rate is zeroed /
    /// status emitted on the MainActor.
    ///
    /// - Parameters:
    ///   - silent: If `true`, skips all status updates to avoid UI flicker.
    /// - Note: Combines `silent` and non-user reasons into `effectiveSilent`.
    @MainActor
    func performActualStop(
        reason: StopReason,
        silent: Bool = false
    ) async {
        // Derive effectiveSilent exactly as before, but now driven by reason
        // (preserves all recent-commit behaviour for silent + stream switches)
        let effectiveSilent = silent || (reason != .userAction)
        let usesSoftPause = reason == .userAction && !effectiveSilent

        if !usesSoftPause {
            activatePlaybackTeardownGuardFromStop()
        }
        clearSSLProtectionTimer()
        isSSLHandshakeComplete = true
        hasStartedPlaying = false
        isDeferringFirstPlayKick = false
        
        if isDeallocating {
            stopSynchronously()
            return
        }

        // Soft pause: silence on MainActor immediately (no audioQueue hop). Return only after
        // rate == 0 and isSoftPaused so surface refresh cannot race audible audio.
        if usesSoftPause {
            cancelStartupSafetyNet()
            cancelEarlyICYDropRecreate()
            player?.pause()
            player?.rate = 0.0
            isSoftPaused = true
            lastEmittedStatus = nil
            lastObservedTimeControl = nil
            lastObservedItemStatus = nil
            safeOnStatusChange(isPlaying: false, reasonKey: "status_stopped")
            #if DEBUG
            print("[DirectStreamingPlayer] Soft pause complete — rate 0, secured AVPlayerItem retained for same-stream resume")
            #endif
            return
        }

        // Hard teardown: bridge audioQueue work with a single continuation resume on MainActor.
        // Resume is always scheduled via main.async so it never runs on the same stack as
        // withCheckedContinuation’s body.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            audioQueue.async { [weak self] in
                guard let self, !self.isDeallocating else {
                    DispatchQueue.main.async {
                        continuation.resume()
                    }
                    return
                }

                #if DEBUG
                print("[DirectStreamingPlayer] Stopping playback (reason: \(reason), effectiveSilent: \(effectiveSilent))")
                #endif

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.isSoftPaused = false
                    }
                }

                guard self.player != nil || self.playerItem != nil else {
                    if !effectiveSilent {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self.safeOnStatusChange(isPlaying: false, reasonKey: "status_stopped")
                            }
                            continuation.resume()
                        }
                    } else {
                        DispatchQueue.main.async {
                            continuation.resume()
                        }
                    }
                    #if DEBUG
                    print("[DirectStreamingPlayer] Playback already stopped, skipping cleanup (reason: \(reason))")
                    #endif
                    return
                }

                // Pause + cleanup
                self.executeAudioOperation({
                    self.player?.pause()
                    self.player?.rate = 0.0
                    return ""
                }, completion: { _ in })

                self.activeResourceLoaders.forEach { (_, delegate) in
                    delegate.cancel()
                }
                self.activeResourceLoaders.removeAll()

                if let metadataOutput = self.metadataOutput, let playerItem = self.playerItem {
                    if playerItem.outputs.contains(metadataOutput) {
                        playerItem.remove(metadataOutput)
                        #if DEBUG
                        print("[DirectStreamingPlayer] Removed metadata output from playerItem in stop")
                        #endif
                    }
                }
                self.metadataOutput = nil

                self.playerItemObservations.forEach { $0.invalidate() }
                self.playerItemObservations.removeAll()
                self.removeObserversImplementation()
                self.playerItem = nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.clearAttachedItemBinding()
                    }
                }

                if !effectiveSilent {
                    // A real terminal stop is a context change — clear dedup so the
                    // "status_stopped" we are about to emit (and any subsequent play) is not suppressed.
                    lastEmittedStatus = nil
                    lastObservedTimeControl = nil
                    lastObservedItemStatus = nil

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.safeOnStatusChange(isPlaying: false, reasonKey: "status_stopped")
                        }
                        continuation.resume()
                    }
                } else {
                    DispatchQueue.main.async {
                        continuation.resume()
                    }
                }

                self.stopBufferingTimer()

                #if DEBUG
                print("[DirectStreamingPlayer] Playback stopped, playerItem and resource loaders cleared (reason: \(reason))")
                #endif
            }
        }
    }
    
    func stopSynchronously() {
        // Perform all cleanup on main thread
        if Thread.isMainThread {
            player?.pause()
            player?.rate = 0.0
        } else {
            DispatchQueue.main.sync {
                player?.pause()
                player?.rate = 0.0
            }
        }
        
        // Cancel active resource loaders
        activeResourceLoaders.forEach { (_: AVAssetResourceLoadingRequest, delegate: StreamingSessionDelegate) in
            delegate.cancel()
        }
        activeResourceLoaders.removeAll()
        
        // Remove metadata output
        if let metadataOutput = self.metadataOutput, let playerItem = self.playerItem {
            if playerItem.outputs.contains(metadataOutput) {
                playerItem.remove(metadataOutput)
            }
        }
        self.metadataOutput = nil
        
        // Remove observers synchronously
        removeObserversSynchronously()
        
        // Clear playerItem
        playerItem = nil
        if Thread.isMainThread {
            MainActor.assumeIsolated { clearAttachedItemBinding() }
        }
        
        // Stop buffering timer
        bufferingTimer?.invalidate()
        bufferingTimer = nil
    }
    
    func performStopCleanup() {
        // Original stop logic without weak references
        guard player != nil || playerItem != nil else {
            return
        }
        
        player?.pause()
        player?.rate = 0.0
        
        activeResourceLoaders.forEach { (_: AVAssetResourceLoadingRequest, delegate: StreamingSessionDelegate) in
            delegate.cancel()
        }
        activeResourceLoaders.removeAll()
        
        if let metadataOutput = self.metadataOutput, let playerItem = self.playerItem {
            if playerItem.outputs.contains(metadataOutput) {
                playerItem.remove(metadataOutput)
            }
        }
        self.metadataOutput = nil
        
        removeObserversImplementation()
        playerItem = nil
        if Thread.isMainThread {
            MainActor.assumeIsolated { clearAttachedItemBinding() }
        }
        stopBufferingTimer()
    }
    
    
    func clearCallbacks() {
        onStatusChange = nil
        onMetadataChange = nil
        onNetworkPathChange = nil
        delegate = nil
    }
    
    deinit {
        isDeallocating = true
        
        // Cancel pending work items that exist
        serverSelectionWorkItem?.cancel()
        retryWorkItem?.cancel()
        
        #if DEBUG
        print("[DirectStreamingPlayer] [Deinit] Cancelled pending work items")
        #endif
        
        // Stop synchronously to avoid async cleanup during deallocation
        stopSynchronously()
        
        playerItemObservations.forEach { $0.invalidate() }
        playerItemObservations.removeAll()
        
        // Clear all callbacks to prevent retention cycles
        clearCallbacks()
        
        // Cancel network monitoring
        networkMonitor?.cancel()
        networkMonitor = nil
        
        // Clear metadata output
        metadataOutput = nil
        
        // Clear server failure tracking
        serverFailureCount.removeAll()
        lastFailedServerName = nil
        
        // Cleanup thermal observer
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        // Clean up Low Power Mode observer to prevent memory leaks.
        NotificationCenter.default.removeObserver(self, name: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"), object: nil)
        
        // MARK: - Additional Deinit Cleanup
        removeAudioSessionObservers()
        clearAllSSLProtectionTimers()  // Ensure existing SSL cleanup runs
        
        #if DEBUG
        print("[DirectStreamingPlayer] deinit completed")
        #endif
    }
    
}


// Extension to get unique elements from a sequence
extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

