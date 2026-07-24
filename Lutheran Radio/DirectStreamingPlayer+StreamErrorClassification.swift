//
//  DirectStreamingPlayer+StreamErrorClassification.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Main-app StreamErrorType classification from AVFoundation / URLError for permanent vs transient recovery.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public façade; this file owns one domain.
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is
//  file-scoped). Prefer this domain file over re-implementing attach / recovery
//  / catalog logic in call sites.
//
//  - SeeAlso: DirectStreamingPlayer.swift, WidgetSurface.StreamErrorType, DirectStreamingPlayer+PlayerItemRecovery.swift,
//    CODING_AGENT.md (Single Source of Truth Principles).
//

import Foundation
@unsafe @preconcurrency import AVFoundation
import WidgetSurface

// MARK: - StreamErrorType classification (main-app implementation)

extension StreamErrorType {
    /// Classifies the given error.
    ///
    /// - Parameter error: The `item.error` or equivalent from AVFoundation / resource loading.
    /// - Returns: The appropriate ``StreamErrorType``.
    ///
    /// Classifies networking and AVFoundation failures for recovery vs terminal UI.
    ///
    /// Permanent classifications never auto-recreate. Transient and unknown classifications
    /// may enter the early-window secured ``DirectStreamingPlayer`` recreate path.
    ///
    /// - Parameter error: `AVPlayerItem.error`, resource-loader failure, or equivalent.
    /// - Returns: The appropriate ``StreamErrorType``.
    /// - SeeAlso: `handleItemStatusFailure(_:)`, `attemptEarlyWindowTransientRecovery`,
    ///   `recreatePlayerItem()`, `switchToStream(_:)`,
    ///   `resetInitialPlaybackCountersForNewStream()`,
    ///   CODING_AGENT.md (explicit permanent vs transient modeling).
    static func from(error: Error?) -> StreamErrorType {
        guard let nsError = error as NSError? else {
            return .unknown
        }

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case URLError.Code.secureConnectionFailed.rawValue,
                 URLError.Code.serverCertificateUntrusted.rawValue:
                return .securityFailure

            case URLError.Code.fileDoesNotExist.rawValue,
                 URLError.Code.cannotConnectToHost.rawValue,
                 URLError.Code.resourceUnavailable.rawValue:
                return .permanentFailure

            case URLError.Code.cannotFindHost.rawValue,
                 URLError.Code.dnsLookupFailed.rawValue,
                 URLError.Code.badServerResponse.rawValue,
                 URLError.Code.timedOut.rawValue,
                 URLError.Code.networkConnectionLost.rawValue,
                 URLError.Code.notConnectedToInternet.rawValue:
                return .transientFailure

            default:
                return .transientFailure
            }
        }

        if nsError.domain == AVFoundationErrorDomain {
            // Live ICY/Fig decoder noise is almost always recoverable. Only mark clearly
            // terminal AV codes permanent so early-window recreate remains available for
            // the common decoder / media-services paths.
            switch nsError.code {
            case AVError.Code.contentIsUnavailable.rawValue,
                 AVError.Code.noLongerPlayable.rawValue,
                 AVError.Code.formatUnsupported.rawValue:
                return .permanentFailure
            case AVError.Code.mediaServicesWereReset.rawValue,
                 AVError.Code.decodeFailed.rawValue,
                 AVError.Code.undecodableMediaData.rawValue,
                 AVError.Code.failedToParse.rawValue,
                 AVError.Code.decoderNotFound.rawValue,
                 AVError.Code.fileFormatNotRecognized.rawValue:
                return .transientFailure
            default:
                return .transientFailure
            }
        }

        return .transientFailure
    }

    /// The localized status reason key to emit for this classification.
    var statusString: String {
        switch self {
        case .securityFailure:
            return String(localized: "status_security_failed", table: "Localizable")
        case .permanentFailure:
            return String(localized: "status_failed", table: "Localizable")
        case .transientFailure:
            return String(localized: "status_buffering", table: "Localizable")
        case .unknown:
            return String(localized: "status_connecting", table: "Localizable")
        @unknown default:
            return String(localized: "status_connecting", table: "Localizable")
        }
    }

    /// True only for errors that should never be auto-recovered.
    var isPermanent: Bool {
        switch self {
        case .securityFailure, .permanentFailure:
            return true
        case .transientFailure, .unknown:
            return false
        @unknown default:
            return false
        }
    }
}
