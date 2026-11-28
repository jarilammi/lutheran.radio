//
//  DirectStreamingPlayer+StationCapacity.swift
//  Lutheran Radio
//
//  One listener-capacity or missing-upstream answer from a production region.
//
//  nginx on each region terminates TLS for the stream host, then proxies to
//  Liquidsoap. The phone never talks to Liquidsoap. A full edge answers HTTP 503
//  or 429. An edge with nothing to send answers HTTP 404, 502, or 504. After
//  headers have already arrived, `AVError.contentIsUnavailable` and
//  `AVError.noLongerPlayable` are the same missing upstream.
//
//  The attempt may attach the other production region once. That flag is memory
//  for the current ``playbackAttachGeneration`` only. It is not
//  ``embeddedSecurityModelClusterRejections``, and it is not written to
//  UserDefaults. HTTP 403 stays the embedded-model walk and never selects these
//  pills. HTTP 500, timeouts, and a dropped connection with no status line stay
//  on the early-window recreate path.
//
//  - SeeAlso: ``StreamingSessionDelegate``,
//    ``DirectStreamingPlayer/handleLoadingError(_:)``,
//    ``DirectStreamingPlayer/handleItemStatusFailure(_:)``,
//    ``DirectStreamingPlayer/noteEmbeddedSecurityModelRejection(url:statusCode:)``,
//    ``PlayerViewModel/stationTerminalStatusKey``,
//    CODING_AGENT.md (explicit permanent vs transient modeling).

import Foundation
@unsafe @preconcurrency import AVFoundation
import Synchronization
import Core

/// What one answered region means for the main-player status pill.
enum StationCapacityCondition: Equatable, Sendable {
    /// HTTP 503 or 429. The edge refused another listener.
    case crowded
    /// HTTP 404, 502, or 504, or the item became unplayable after headers arrived.
    case resource
}

/// What the resource loader should do with one capacity status on this attach.
enum StationCapacityDisposition: Equatable, Sendable {
    /// Not HTTP 503, 429, 404, 502, or 504. The caller keeps the existing branch.
    case notThisResponse
    /// The attach generation is closed. Do not open the other region.
    case ignored
    /// A second callback for the region that already started the one failover.
    case joinInFlight
    /// Attach this other production subdomain once. The refused URL is not rebuilt.
    case failoverOnce(String)
    /// The attempt is finished. The associated value is the pill condition.
    case terminal(StationCapacityCondition)
}

/// In-memory record of capacity answers for one ``playbackAttachGeneration``.
///
/// Not the embedded-model rejection set. A 403 must not be inserted here, and a
/// later 503 must not clear that set.
struct StationCapacityAttemptState: Sendable {
    var generation: UInt64 = 0
    /// `false` after ``stop(reason:completion:silent:applyUserPauseVisualLock:)`` until the next attach begins.
    var acceptingResponses = true
    /// Condition each production subdomain (`eu` / `us`) answered with.
    var answers: [String: StationCapacityCondition] = [:]
    /// Answers that had no production region, including a loader error with no host.
    var unscoped: [StationCapacityCondition] = []
    var contentUnavailable = false
    /// Set when headers already arrived. No second region is opened.
    var suppressFailover = false
    var failoverConsumed = false
    var failoverInFlight = false
    var failoverSourceSubdomain: String?
    var pendingFailoverSubdomain: String?
    var didEmitTerminal = false
}

extension DirectStreamingPlayer {

    /// `userInfo` flag on HTTP 502 and 504.
    ///
    /// Those statuses use ``URLError/badServerResponse`` so a generic HTTP 500,
    /// which uses the same code with this key absent, stays transient.
    static let stationCapacityResourceUserInfoKey = "LutheranRadioStationCapacityResource"

    /// Maps a stream HTTP status onto the capacity error, when it is one.
    ///
    /// - Parameter statusCode: Status line from the stream response. The body is not read.
    /// - Returns: `nil` for every status other than 503, 429, 404, 502, and 504.
    ///   HTTP 403 is `nil` so the embedded-model branch remains the only 403 path.
    /// - SeeAlso: ``noteStationCapacityHTTPResponse(url:statusCode:)``
    static func stationCapacityURLError(statusCode: Int) -> URLError? {
        switch statusCode {
        case 503, 429:
            return URLError(.resourceUnavailable)
        case 404:
            return URLError(.fileDoesNotExist)
        case 502, 504:
            return URLError(
                .badServerResponse,
                userInfo: [stationCapacityResourceUserInfoKey: true]
            )
        default:
            return nil
        }
    }

    /// Condition for a status line, or `nil` when this mechanism does not apply.
    static func stationCapacityCondition(statusCode: Int) -> StationCapacityCondition? {
        switch statusCode {
        case 503, 429:
            return .crowded
        case 404, 502, 504:
            return .resource
        default:
            return nil
        }
    }

    /// Condition carried by a loader or item error.
    ///
    /// HTTP 502 and 504 are ``URLError/badServerResponse`` plus
    /// ``stationCapacityResourceUserInfoKey``. A `badServerResponse` without that
    /// key, including HTTP 500, returns `nil` and stays transient.
    /// ``URLError/fileDoesNotExist`` is HTTP 404. ``URLError/resourceUnavailable``
    /// is HTTP 503 or 429. `AVError.contentIsUnavailable` and
    /// `AVError.noLongerPlayable` are resource and do not open the other region.
    static func stationCapacityCondition(for error: Error) -> StationCapacityCondition? {
        let nsError = error as NSError
        if userInfoMarksStationCapacityResource(nsError.userInfo) {
            return .resource
        }
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case URLError.Code.resourceUnavailable.rawValue:
                return .crowded
            case URLError.Code.fileDoesNotExist.rawValue:
                return .resource
            default:
                return nil
            }
        }
        if nsError.domain == AVFoundationErrorDomain {
            switch nsError.code {
            case AVError.Code.contentIsUnavailable.rawValue,
                 AVError.Code.noLongerPlayable.rawValue:
                return .resource
            default:
                return nil
            }
        }
        return nil
    }

    /// `true` for an item that already received headers and then became unplayable.
    static func isPlayedResourceUnavailable(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == AVFoundationErrorDomain else { return false }
        return nsError.code == AVError.Code.contentIsUnavailable.rawValue
            || nsError.code == AVError.Code.noLongerPlayable.rawValue
    }

    /// Pill key for the finished attempt.
    ///
    /// Resource wins when any answered region used it, or the item was unplayable
    /// after headers. Crowded only when every answered region used 503 or 429.
    static func stationCapacityReasonKey(conditions: [StationCapacityCondition]) -> String? {
        guard let aggregate = stationCapacityAggregate(conditions) else { return nil }
        switch aggregate {
        case .crowded:
            return "status_crowded"
        case .resource:
            return "status_resource"
        }
    }

    /// Crowded only when every condition is crowded. Any resource selects resource.
    static func stationCapacityAggregate(
        _ conditions: [StationCapacityCondition]
    ) -> StationCapacityCondition? {
        guard !conditions.isEmpty else { return nil }
        if conditions.contains(.resource) {
            return .resource
        }
        return .crowded
    }

    /// Records one capacity status for this attach generation.
    ///
    /// Safe to call from the URLSession delegate queue. The insert is visible
    /// before the caller finishes the loading request, so a same-URL recreate
    /// sees the answered region. Does not insert into
    /// ``embeddedSecurityModelClusterRejections``.
    ///
    /// - Parameters:
    ///   - url: Stream URL the origin answered.
    ///   - statusCode: HTTP status. 403 returns ``StationCapacityDisposition/notThisResponse``.
    /// - Returns: Failover, join, terminal, or not this response.
    /// - SeeAlso: ``performStationCapacityFailover()``,
    ///   ``stationCapacitySecurityModelTookOver()``
    func noteStationCapacityHTTPResponse(
        url: URL,
        statusCode: Int
    ) -> StationCapacityDisposition {
        guard let condition = Self.stationCapacityCondition(statusCode: statusCode) else {
            return .notThisResponse
        }
        let apex = SecurityConfiguration.current.preferredStreamingDomainSuffix
        let productionSubdomains = Self.servers.map(\.subdomain)
        let failed = url.host.flatMap {
            Self.productionClusterSubdomain(
                host: $0,
                apex: apex,
                productionSubdomains: productionSubdomains
            )
        }
        let rejected = embeddedSecurityModelRejectedSubdomains()
        return stationCapacityAttempt.withLock { state in
            guard state.acceptingResponses else { return .ignored }
            if let failed {
                Self.recordStationCapacityAnswer(condition, for: failed, in: &state)
                if state.suppressFailover {
                    state.failoverInFlight = false
                    state.pendingFailoverSubdomain = nil
                    return .terminal(Self.aggregateCondition(in: state) ?? condition)
                }
                if state.failoverInFlight {
                    if failed == state.failoverSourceSubdomain {
                        return .joinInFlight
                    }
                    state.failoverInFlight = false
                    state.pendingFailoverSubdomain = nil
                    return .terminal(Self.aggregateCondition(in: state) ?? condition)
                }
                if !state.failoverConsumed,
                   let next = Self.alternateEligibleCluster(
                    currentSubdomain: failed,
                    rejectedSubdomains: rejected,
                    servers: Self.servers
                   ) {
                    state.failoverConsumed = true
                    state.failoverInFlight = true
                    state.failoverSourceSubdomain = failed
                    state.pendingFailoverSubdomain = next.subdomain
                    return .failoverOnce(next.subdomain)
                }
                return .terminal(Self.aggregateCondition(in: state) ?? condition)
            }
            state.unscoped.append(condition)
            state.failoverInFlight = false
            state.pendingFailoverSubdomain = nil
            return .terminal(Self.aggregateCondition(in: state) ?? condition)
        }
    }

    /// Records resource after headers arrived. Does not open the other region.
    ///
    /// - Parameter url: Item URL, when the asset has one.
    /// - Returns: ``StationCapacityDisposition/terminal(_:)`` with resource, or
    ///   ``StationCapacityDisposition/ignored`` when the generation is closed.
    func noteStationContentUnavailable(url: URL?) -> StationCapacityDisposition {
        let apex = SecurityConfiguration.current.preferredStreamingDomainSuffix
        let productionSubdomains = Self.servers.map(\.subdomain)
        let subdomain = url?.host.flatMap {
            Self.productionClusterSubdomain(
                host: $0,
                apex: apex,
                productionSubdomains: productionSubdomains
            )
        }
        return stationCapacityAttempt.withLock { state in
            guard state.acceptingResponses else { return .ignored }
            state.contentUnavailable = true
            state.suppressFailover = true
            state.failoverInFlight = false
            state.pendingFailoverSubdomain = nil
            if let subdomain {
                state.answers[subdomain] = .resource
            } else {
                state.unscoped.append(.resource)
            }
            return .terminal(.resource)
        }
    }

    /// Ends the capacity join window because HTTP 403 took the embedded-model walk.
    ///
    /// Does not clear answers or the one-failover flag. A later 503 or 502 on this
    /// generation stops instead of opening another capacity attach.
    func stationCapacitySecurityModelTookOver() {
        stationCapacityAttempt.withLock { state in
            state.failoverInFlight = false
            state.pendingFailoverSubdomain = nil
        }
    }

    /// `true` when this URL's production region already answered a capacity status.
    ///
    /// Same-URL ``recreatePlayerItem(securedURL:)`` returns before building an item.
    /// The other region's URL is not in the map until that region answers.
    func stationCapacityRegionAlreadyAnswered(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        let apex = SecurityConfiguration.current.preferredStreamingDomainSuffix
        guard let subdomain = Self.productionClusterSubdomain(
            host: host,
            apex: apex,
            productionSubdomains: Self.servers.map(\.subdomain)
        ) else {
            return false
        }
        return stationCapacityAttempt.withLock { state in
            state.acceptingResponses && state.answers[subdomain] != nil
        }
    }

    /// One attach on the other production region for this generation.
    ///
    /// Skips a region already in ``embeddedSecurityModelClusterRejections``.
    /// Does not call ``attemptEarlyWindowTransientRecovery(reason:allowWhileDeferringFirstPlayKick:)``
    /// and does not rebuild the URL that just refused. Under UITestMode the URL
    /// is recorded and no item is built.
    ///
    /// - SeeAlso: ``noteStationCapacityHTTPResponse(url:statusCode:)``,
    ///   ``finishStationCapacityAttempt()``
    @MainActor
    func performStationCapacityFailover() async {
        cancelStartupSafetyNet()
        cancelEarlyICYDropRecreate()
        let subdomain = stationCapacityAttempt.withLock { $0.pendingFailoverSubdomain }
        guard let subdomain,
              isProductionClusterEligible(subdomain),
              let server = Self.servers.first(where: { $0.subdomain == subdomain }) else {
            await finishStationCapacityAttempt()
            return
        }
        currentSelectedServer = server
        let url = StreamCatalog.streamURL(
            languageCode: selectedStream.languageCode,
            region: subdomain
        )
        test_lastStationCapacityFailoverURL = url
        guard !isTesting else { return }
        recreatePlayerItem(securedURL: url)
    }

    /// Stops the attempt and emits `status_crowded` or `status_resource`.
    ///
    /// ``SharedPlayerManager/markPlaybackStoppedByStreamFailure(_:)`` stays
    /// ``StreamErrorType/permanentFailure`` for both pills. Intent is unchanged.
    /// The alert is the status callback, and it is not emitted while a failover
    /// attach is still the disposition. Under UITestMode the reason key is
    /// recorded and no status, Live Activity, or audio teardown runs.
    @MainActor
    func finishStationCapacityAttempt() async {
        guard let reasonKey = takeStationCapacityTerminalReasonKey() else { return }
        test_lastStationCapacityReasonKey = reasonKey
        guard !isTesting else { return }
        safeOnStatusChange(isPlaying: false, reasonKey: reasonKey)
        await SharedPlayerManager.shared.markPlaybackStoppedByStreamFailure(.permanentFailure)
        stop(reason: .error, silent: true, applyUserPauseVisualLock: false)
    }

    /// Records a capacity error that arrived without a stream URL.
    ///
    /// Used by ``handleLoadingError(_:)`` so the same codes do not enter
    /// early-window recreate. Does not open the other region.
    func absorbUnscopedStationCapacity(_ condition: StationCapacityCondition) {
        stationCapacityAttempt.withLock { state in
            guard state.acceptingResponses else { return }
            state.unscoped.append(condition)
            state.failoverInFlight = false
            state.pendingFailoverSubdomain = nil
            state.failoverConsumed = true
        }
    }

    /// Aligns this record with ``playbackAttachGeneration``.
    ///
    /// A new generation drops the answers and the one-failover flag so a later
    /// Play can attach again. Closing the current generation does the same and
    /// ignores a late status callback.
    func adoptStationCapacityGeneration(_ generation: UInt64, acceptingResponses: Bool) {
        stationCapacityAttempt.withLock { state in
            if state.generation != generation {
                state = StationCapacityAttemptState(
                    generation: generation,
                    acceptingResponses: acceptingResponses
                )
            } else if !acceptingResponses {
                state = StationCapacityAttemptState(
                    generation: generation,
                    acceptingResponses: false
                )
            } else {
                state.acceptingResponses = true
            }
        }
    }

    /// Clears the process-local capacity record. Unit tests call this so a case cannot leak.
    func test_resetStationCapacityAttempt() {
        let generation = playbackAttachGeneration
        stationCapacityAttempt.withLock { state in
            state = StationCapacityAttemptState(
                generation: generation,
                acceptingResponses: true
            )
        }
        test_lastStationCapacityFailoverURL = nil
        test_lastStationCapacityReasonKey = nil
    }

    private func takeStationCapacityTerminalReasonKey() -> String? {
        stationCapacityAttempt.withLock { state in
            if state.didEmitTerminal { return nil }
            let conditions = Self.conditions(in: state)
            guard let reasonKey = Self.stationCapacityReasonKey(conditions: conditions) else {
                return nil
            }
            state.didEmitTerminal = true
            state.failoverInFlight = false
            state.pendingFailoverSubdomain = nil
            return reasonKey
        }
    }

    /// HTTP 502 and 504 set this flag. `URLError` may bridge `Bool` to `NSNumber`.
    private static func userInfoMarksStationCapacityResource(_ userInfo: [String: Any]) -> Bool {
        let flag = userInfo[stationCapacityResourceUserInfoKey]
        if (flag as? Bool) == true {
            return true
        }
        if let number = flag as? NSNumber {
            return number.boolValue
        }
        return false
    }

    private static func recordStationCapacityAnswer(
        _ condition: StationCapacityCondition,
        for subdomain: String,
        in state: inout StationCapacityAttemptState
    ) {
        if state.answers[subdomain] == .resource {
            return
        }
        state.answers[subdomain] = condition
    }

    private static func conditions(in state: StationCapacityAttemptState) -> [StationCapacityCondition] {
        var conditions = Array(state.answers.values) + state.unscoped
        if state.contentUnavailable {
            conditions.append(.resource)
        }
        return conditions
    }

    private static func aggregateCondition(
        in state: StationCapacityAttemptState
    ) -> StationCapacityCondition? {
        stationCapacityAggregate(conditions(in: state))
    }
}
