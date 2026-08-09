//
//  HomeWidgetLiveChrome.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 30.7.2026.
//
//  Privacy-gated live home/Control chrome payload for App Group projection.
//
//  WidgetSurface framework — presentation-only (no security logic).
//
//  Purpose:
//  Codable blob written to App Group key `homeWidgetLiveChrome` so extension Providers can
//  paint visual + language + hasError while the main process is alive and home widgets are
//  installed. Session-scoped only — never used for cold-launch play resurrection (OI-1).
//
//  Key invariants:
//  - Encodes ``PlayerVisualState`` as a stable case-name token (not brittle enum index).
//  - Unknown visual tokens fail decode so load helpers treat the mirror as absent.
//  - Does **not** embed program title/speaker — that remains ``StreamProgramMetadata`` /
//    `homeWidgetStreamMetadata` (single concern).
//  - No security logic; writers/readers and privacy gates live on ``SharedPlayerManager``.
//
//  - SeeAlso: ``PlayerVisualState``, ``StreamProgramMetadata``,
//    SharedPlayerManager persist/load/clear home live-chrome helpers,
//    docs/Home-Live-Chrome-App-Group-Mirror-Design.md,
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation

/// Privacy-gated live home/Control chrome for extension Providers.
///
/// Session-scoped projection of visual + language + permanent-error flag. Never used for
/// cold-launch resurrection of play state (OI-1). Main app and extension optimistic paths
/// stamp via privacy-gated App Group helpers; Providers resolve session vs this mirror by
/// **chrome-field agreement + wall-clock freshness** (see ``resolveHomeWidgetChromeFields``),
/// then factory defaults.
///
/// - Important: Unknown `visualState` tokens must fail decode so load returns `nil` (safe
///   absent path), never crash or invent a visual.
/// - SeeAlso: ``PlayerVisualState``, ``resolveHomeWidgetChromeFields``,
///   `SharedPlayerManager.persistHomeWidgetLiveChromeMirror`,
///   `SharedPlayerManager.loadHomeWidgetLiveChromeMirror`,
///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md.
public struct HomeWidgetLiveChrome: Codable, Equatable, Sendable {
    /// Presentation visual for status/control derivation (never invent mid-hold playing).
    public var visualState: PlayerVisualState

    /// Stream language code for flag / station label / chips.
    public var currentLanguage: String

    /// Permanent-error chrome flag (security / unrecoverable network).
    public var hasError: Bool

    /// Wall-clock of last authoritative or optimistic stamp (epoch seconds).
    public var updatedAt: TimeInterval

    /// Optional generation or reason token for DEBUG / future coalesce (not required for paint).
    public var stampReason: String?

    /// Creates a live-chrome payload for App Group projection.
    ///
    /// - Parameters:
    ///   - visualState: Presentation visual (encoded as a stable case-name token).
    ///   - currentLanguage: Non-empty language code expected by load hygiene.
    ///   - hasError: Permanent-error chrome flag.
    ///   - updatedAt: Stamp wall-clock (epoch seconds).
    ///   - stampReason: Optional DEBUG / coalesce reason (e.g. `"setPlaying"`, `"stickyPause"`).
    /// - SeeAlso: docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§3 payload).
    public init(
        visualState: PlayerVisualState,
        currentLanguage: String,
        hasError: Bool,
        updatedAt: TimeInterval,
        stampReason: String? = nil
    ) {
        self.visualState = visualState
        self.currentLanguage = currentLanguage
        self.hasError = hasError
        self.updatedAt = updatedAt
        self.stampReason = stampReason
    }

    // MARK: - Codable (stable visual token)

    private enum CodingKeys: String, CodingKey {
        case visualState
        case currentLanguage
        case hasError
        case updatedAt
        case stampReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let token = try container.decode(String.self, forKey: .visualState)
        guard let decodedVisual = Self.playerVisualState(fromStableToken: token) else {
            throw DecodingError.dataCorruptedError(
                forKey: .visualState,
                in: container,
                debugDescription: "Unknown homeWidgetLiveChrome visual token: \(token)"
            )
        }
        visualState = decodedVisual
        currentLanguage = try container.decode(String.self, forKey: .currentLanguage)
        hasError = try container.decode(Bool.self, forKey: .hasError)
        updatedAt = try container.decode(TimeInterval.self, forKey: .updatedAt)
        stampReason = try container.decodeIfPresent(String.self, forKey: .stampReason)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.stableToken(for: visualState), forKey: .visualState)
        try container.encode(currentLanguage, forKey: .currentLanguage)
        try container.encode(hasError, forKey: .hasError)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(stampReason, forKey: .stampReason)
    }

    // MARK: - Stable visual tokens

    /// Stable case-name token for App Group encode (binary-compatible across minor refactors).
    ///
    /// - Parameter state: Visual case to project.
    /// - Returns: Case-name string (e.g. `"playing"`, `"userPaused"`).
    /// - SeeAlso: ``playerVisualState(fromStableToken:)``.
    public static func stableToken(for state: PlayerVisualState) -> String {
        switch state {
        case .prePlay: return "prePlay"
        case .cleared: return "cleared"
        case .playing: return "playing"
        case .userPaused: return "userPaused"
        case .thermalPaused: return "thermalPaused"
        case .securityLocked: return "securityLocked"
        }
    }

    /// Decodes a stable visual token; unknown tokens return `nil` (mirror treated as absent).
    ///
    /// - Parameter token: Case-name string from App Group JSON.
    /// - Returns: Matching ``PlayerVisualState``, or `nil` when unknown.
    /// - SeeAlso: ``stableToken(for:)``.
    public static func playerVisualState(fromStableToken token: String) -> PlayerVisualState? {
        switch token {
        case "prePlay": return .prePlay
        case "cleared": return .cleared
        case "playing": return .playing
        case "userPaused": return .userPaused
        case "thermalPaused": return .thermalPaused
        case "securityLocked": return .securityLocked
        default: return nil
        }
    }
}

/// Identity comparison for live-chrome App Group writes (ignore stampReason / small time skew).
///
/// - Parameters:
///   - existing: Previously loaded mirror, if any.
///   - candidate: Chrome about to be stamped.
/// - Returns: `true` when visual + language + hasError match (skip redundant write).
/// - SeeAlso: docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§4).
public func shouldSkipIdenticalHomeWidgetLiveChromeWrite(
    existing: HomeWidgetLiveChrome?,
    candidate: HomeWidgetLiveChrome
) -> Bool {
    guard let existing else { return false }
    return existing.visualState == candidate.visualState
        && existing.currentLanguage == candidate.currentLanguage
        && existing.hasError == candidate.hasError
}

// MARK: - Provider chrome source selection (session vs live chrome freshness)

/// Which source supplied visual / language / hasError for home/Control Provider paint.
///
/// - SeeAlso: ``resolveHomeWidgetChromeFields(sessionVisual:sessionLanguage:sessionHasError:sessionUpdatedAt:liveChrome:)``,
///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§6).
public enum HomeWidgetChromePaintSource: String, Sendable, Equatable {
    /// Process-local session RAM (`PersistedWidgetState`).
    case session
    /// Privacy-gated App Group ``HomeWidgetLiveChrome``.
    case liveChrome
    /// Neither source present — factory ``.prePlay`` / caller language / no error.
    case factory
}

/// Resolved home/Control chrome fields after session-vs-mirror freshness selection.
///
/// - Important: ``currentLanguage`` is `nil` only for the factory path so callers can apply
///   ``preferredWidgetLanguage()``. Non-empty language always comes from the winning source.
/// - SeeAlso: ``resolveHomeWidgetChromeFields(sessionVisual:sessionLanguage:sessionHasError:sessionUpdatedAt:liveChrome:)``.
public struct HomeWidgetResolvedChrome: Equatable, Sendable {
    public var visualState: PlayerVisualState
    public var currentLanguage: String?
    public var hasError: Bool
    public var source: HomeWidgetChromePaintSource

    public init(
        visualState: PlayerVisualState,
        currentLanguage: String?,
        hasError: Bool,
        source: HomeWidgetChromePaintSource
    ) {
        self.visualState = visualState
        self.currentLanguage = currentLanguage
        self.hasError = hasError
        self.source = source
    }
}

/// Chooses home/Control visual + language + hasError from process-local session vs live chrome.
///
/// **Why not rigid session-first:** Extension optimistic switch/hold writes process-local session
/// ``.prePlay`` while main-app settle stamps a **newer** App Group ``homeWidgetLiveChrome``
/// ``.playing``. Rigid session-first left home yellow Connecting while main was green. Freshness
/// comparison lets the newer projection win without inventing mid-hold ``.playing`` when the
/// mirror still holds ``.prePlay``.
///
/// **Policy:**
/// 1. Neither source → factory (``.prePlay``, language `nil`, `hasError == false`).
/// 2. Only one source → that source.
/// 3. Both present and chrome fields agree (visual + comparable language + hasError) → **session**
///    (same-process optimistic continuity; metadata stays with session).
/// 4. Both present and disagree → source with **greater** `updatedAt` wins. **Ties prefer session**
///    except definitive settle pairs (session ``.userPaused`` + mirror ``.playing``, or session
///    ``.playing`` + mirror ``.userPaused``) where equal stamps prefer the App Group mirror so
///    soft-resume / home-pause settle cannot leave residual opposite LIVE chrome.
/// 5. Session missing `sessionUpdatedAt` is treated as older than any positive mirror stamp so a
///    main-app settle mirror can still heal an untimestamped residual session.
/// 6. When ``distrustLiveChrome`` is true (termination sentinel or device reboot boot-identity
///    mismatch at the call site), the App Group mirror is treated as **absent** even if still on
///    disk — residual play/pause glyphs must not paint after dirty process exit / power-off.
///    Process-local session remains usable for same-process optimistic continuity.
///
/// Program metadata is **not** resolved here (session → ``homeWidgetStreamMetadata`` peer).
/// Liveness still owns interactive vs passive — this selection is paint fields only.
///
/// - Parameters:
///   - sessionVisual: Process-local session visual, if any.
///   - sessionLanguage: Process-local session language (empty treated as absent for language paint).
///   - sessionHasError: Process-local permanent-error flag when session exists.
///   - sessionUpdatedAt: Session last-write epoch seconds (`lastLanguageChangeTime`), if known.
///   - liveChrome: Privacy-gated App Group mirror, if present and well-formed.
///   - distrustLiveChrome: When `true`, ignore ``liveChrome`` for paint (wire from
///     ``SharedPlayerManager/shouldDistrustDurableMirrorPlayPlanning()`` at membership-exception
///     call sites). Default `false` preserves pure freshness matrices.
/// - Returns: Paint fields + which source won.
/// - SeeAlso: ``HomeWidgetLiveChrome``, ``HomeWidgetResolvedChrome``,
///   docs/Home-Live-Chrome-App-Group-Mirror-Design.md (§6.1–§6.3),
///   CODING_AGENT.md (Single Source of Truth Principles).
public func resolveHomeWidgetChromeFields(
    sessionVisual: PlayerVisualState?,
    sessionLanguage: String?,
    sessionHasError: Bool?,
    sessionUpdatedAt: TimeInterval?,
    liveChrome: HomeWidgetLiveChrome?,
    distrustLiveChrome: Bool = false
) -> HomeWidgetResolvedChrome {
    // Post-termination / reboot: residual App Group chrome is not a live session. Treat as
    // absent so Providers land factory (or process-local session only), never last play/pause.
    let effectiveLiveChrome = distrustLiveChrome ? nil : liveChrome
    let sessionPresent = sessionVisual != nil
    let mirrorPresent = effectiveLiveChrome != nil

    if !sessionPresent && !mirrorPresent {
        return HomeWidgetResolvedChrome(
            visualState: .prePlay,
            currentLanguage: nil,
            hasError: false,
            source: .factory
        )
    }

    if sessionPresent, !mirrorPresent {
        let language = normalizedChromeLanguage(sessionLanguage)
        return HomeWidgetResolvedChrome(
            visualState: sessionVisual ?? .prePlay,
            currentLanguage: language,
            hasError: sessionHasError ?? false,
            source: .session
        )
    }

    if !sessionPresent, let liveChrome = effectiveLiveChrome {
        return HomeWidgetResolvedChrome(
            visualState: liveChrome.visualState,
            currentLanguage: normalizedChromeLanguage(liveChrome.currentLanguage),
            hasError: liveChrome.hasError,
            source: .liveChrome
        )
    }

    // Both present.
    guard let sVisual = sessionVisual, let mirror = effectiveLiveChrome else {
        // Unreachable when sessionPresent && mirrorPresent; factory is a safe fallback.
        return HomeWidgetResolvedChrome(
            visualState: .prePlay,
            currentLanguage: nil,
            hasError: false,
            source: .factory
        )
    }
    let sLanguage = sessionLanguage ?? ""
    let sHasError = sessionHasError ?? false

    let languagesAgree: Bool = {
        if sLanguage.isEmpty { return true }
        return sLanguage == mirror.currentLanguage
    }()
    let fieldsAgree =
        sVisual == mirror.visualState
        && languagesAgree
        && sHasError == mirror.hasError

    if fieldsAgree {
        let language = normalizedChromeLanguage(sLanguage)
            ?? normalizedChromeLanguage(mirror.currentLanguage)
        return HomeWidgetResolvedChrome(
            visualState: sVisual,
            currentLanguage: language,
            hasError: sHasError,
            source: .session
        )
    }

    // Disagree: fresher wall-clock wins. Untimestamped session is older than any mirror stamp
    // so main settle can heal residual Connecting. Default tie prefers session (same-tick
    // optimistic continuity) **except** definitive pause/play settle pairs where equal stamps
    // would leave residual LIVE chrome: sticky session ``.userPaused`` vs mirror ``.playing``
    // (soft-resume setPlaying) and residual session ``.playing`` vs mirror ``.userPaused``
    // (home pause). Prefer the App Group mirror on those equal-timestamp settles.
    let sessionTime = sessionUpdatedAt ?? -.infinity
    let softResumeSettleTie =
        sVisual == .userPaused && mirror.visualState == .playing
    let pauseSettleTie =
        sVisual == .playing && mirror.visualState == .userPaused
    let mirrorWins =
        mirror.updatedAt > sessionTime
        || ((softResumeSettleTie || pauseSettleTie) && mirror.updatedAt >= sessionTime)
    if mirrorWins {
        return HomeWidgetResolvedChrome(
            visualState: mirror.visualState,
            currentLanguage: normalizedChromeLanguage(mirror.currentLanguage),
            hasError: mirror.hasError,
            source: .liveChrome
        )
    }

    let language = normalizedChromeLanguage(sLanguage)
        ?? normalizedChromeLanguage(mirror.currentLanguage)
    return HomeWidgetResolvedChrome(
        visualState: sVisual,
        currentLanguage: language,
        hasError: sHasError,
        source: .session
    )
}

/// Non-empty language for paint, or `nil` when the source left language unset.
private func normalizedChromeLanguage(_ language: String?) -> String? {
    guard let language, !language.isEmpty else { return nil }
    return language
}
