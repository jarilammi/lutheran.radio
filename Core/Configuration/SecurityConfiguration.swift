//
//  SecurityConfiguration.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 18.3.2026.
//

import Foundation

public struct SecurityConfiguration {
    
    // MARK: - Security Model (DNS TXT validated)
    
    /// The embedded security model this app build enforces.
    /// Must match one of the comma-separated values in the TXT record.
    public let expectedSecurityModel: String = "starbase"
    
    /// Primary domain queried for TXT record containing valid models (comma-separated).
    let primarySecurityModelDomain: String = "securitymodels.lutheran.radio"
    
    /// Backup domain for redundancy (different TLD).
    let backupSecurityModelDomain: String = "securitymodels.lutheranradio.sk"
    
    /// All domains in priority order (primary → backup)
    /// Computed property to avoid Swift property initializer ordering issues.
    var securityModelDomains: [String] {
        [
            primarySecurityModelDomain,
            backupSecurityModelDomain
        ]
    }
    
    /// Cache duration for successful security model validation results.
    /// After this interval, re-query the TXT record.
    let modelCacheDuration: TimeInterval = 3_600  // 1 hour
    
    
    // MARK: - Certificate Pinning (runtime full-chain validation)
    
    /// SHA-256 fingerprint of the leaf certificate (hex, colon-separated).
    /// Used in runtime validation (CertificateValidator / SecurityModelValidator).
    /// This is the primary runtime pin (beyond ATS SPKI).
    let pinnedLeafFingerprint: String = "CC:F7:8E:09:EF:F3:3D:9A:5D:8B:B0:5C:74:28:0D:F6:BE:14:1C:C4:47:F9:69:C2:90:2C:43:97:66:8B:3D:CC"
    
    /// Optional: If you ever support multiple active certificates (e.g. during overlap),
    /// expand to a Set<String>. For now kept as single value for simplicity.
    public var pinnedFingerprints: Set<String> {
        [pinnedLeafFingerprint]
    }
    
    
    // MARK: - Certificate Transition Window
    
    /// Start of the one-month grace period before certificate expiry/rotation.
    /// During this window: runtime pinning failures are lenient (fall back to ATS).
    let transitionWindowStart: Date = {
        var components = DateComponents(calendar: .current, timeZone: .gmt)
        components.year   = 2026
        components.month  = 7
        components.day    = 27
        components.hour   = 0
        components.minute = 0
        components.second = 0
        return Calendar.current.date(from: components) ?? Date.distantFuture
    }()
    
    /// End of the transition window (inclusive).
    /// After this date: strict runtime pinning enforcement (no leniency).
    let transitionWindowEnd: Date = {
        var components = DateComponents(calendar: .current, timeZone: .gmt)
        components.year   = 2026
        components.month  = 8
        components.day    = 26
        components.hour   = 23
        components.minute = 59
        components.second = 59
        return Calendar.current.date(from: components) ?? Date.distantPast
    }()
    
    /// Whether the current date is inside the transition grace period.
    public var isInTransitionWindow: Bool {
        let now = Date()
        return now >= transitionWindowStart && now <= transitionWindowEnd
    }
    
    
    // MARK: - Time Skew Protection
    
    /// Maximum allowed difference between device time and server Date header (seconds).
    /// If exceeded → disable transition leniency even inside window (anti-clock-manipulation).
    let maxAllowedTimeSkew: TimeInterval = 300  // ±5 minutes
    
    
    // MARK: - Convenience / Current Instance
    
    /// Recommended usage: SecurityConfiguration.current (or inject via init)
    public static let current = SecurityConfiguration()
}
