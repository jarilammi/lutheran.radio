//
//  DirectStreamingPlayer+PeriodicCertificateValidation.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.7.2026.
//
//  Engine-owned periodic certificate revalidation timer for the secured streaming
//  engine. Proactively HEAD-checks the currently preferred stream URL on the same
//  cadence as Core's runtime pin-result cache so a failed pin can stop playback
//  without waiting for the next live media challenge.
//
//  Behavior-preserving domain split from DirectStreamingPlayer.swift.
//  DirectStreamingPlayer remains the public engine façade; this file owns one domain.
//
//  Ownership (do not invert):
//  - This domain owns **periodic certificate validation lifecycle**:
//    ``startPeriodicValidation()`` and ``stopPeriodicCertificateValidation()``.
//  - Timer *storage* (``certificateValidationTimer``) remains on the façade class body
//    (extensions cannot declare stored properties).
//  - Runtime pin policy, digest comparison, transition-window leniency, and the
//    success cache live exclusively in Core (`CertificateValidator`,
//    `SecurityConfiguration`). This domain only schedules and reacts to results.
//  - Playback stop on failure uses ``stop()`` (PlaybackControl domain) and status
//    delivery via ``safeOnStatusChange`` (StatusCallbackDelivery domain) — never
//    re-implements soft/hard stop or status hops here.
//  - Adaptive SSL *handshake* timers remain in `+SSLProtection.swift` (different
//    domain: connect-time handshake budget, not periodic pin revalidation).
//
//  Security invariant:
//  - Validation always goes through ``CertificateValidator/validateServerCertificate(for:)``
//    with the *current* ``selectedStream.url`` (includes preferred server + security_model).
//  - Cadence must read ``SecurityConfiguration/certificateValidationCacheDuration`` —
//    never hard-code 600, never reuse ``modelCacheDuration`` (DNS TXT 1-hour cache).
//  - Never bypass Core pins, SPKI ATS, or DNS TXT validation from this domain.
//
//  Process invariants:
//  - Playback continues optimistically while a background validation Task runs; only
//    a failed result stops the stream on MainActor.
//  - Timer fire uses `[weak self]` so a retained `Timer` cannot keep the engine alive.
//  - ``stopPeriodicCertificateValidation()`` is safe under synchronous deinit (no Task).
//
//  AGENT NOTE: Members used across files are `internal` (Swift `private` is file-scoped).
//  Prefer this domain over re-implementing periodic HEAD revalidation in attach/play
//  paths. Do not mix play/stop entry surgery or SSL handshake timers into this peel.
//
//  - SeeAlso: DirectStreamingPlayer.swift (isolation map, ``certificateValidationTimer``),
//    DirectStreamingPlayer+PlaybackControl.swift (``stop()``),
//    DirectStreamingPlayer+StatusCallbackDelivery.swift (``safeOnStatusChange``),
//    DirectStreamingPlayer+SSLProtection.swift (handshake timers — distinct),
//    DirectStreamingPlayer+DeinitHygiene.swift (calls ``stopPeriodicCertificateValidation()``),
//    Core/Security/CertificateValidator.swift,
//    Core/Configuration/SecurityConfiguration.swift
//    (``certificateValidationCacheDuration``),
//    CODING_AGENT.md (Core Framework Surface Area, Security Model).
//

import Foundation
import Core

// MARK: - Periodic certificate validation

extension DirectStreamingPlayer {

    /// Starts periodic certificate validation against the *currently preferred* URL
    /// (automatically follows server selection changes – if the app switches to a better cluster,
    /// the next validation will check the new cluster’s cert. Since both clusters use the same cert,
    /// this is safe and gives us early detection if one cluster ever diverges).
    ///
    /// Cadence matches ``SecurityConfiguration/certificateValidationCacheDuration`` so proactive
    /// HEAD checks stay aligned with the runtime pin-result cache (not the 1-hour DNS model cache).
    ///
    /// - Postcondition: Any previous periodic timer is invalidated; a new repeating timer is
    ///   scheduled on the run loop used by `Timer.scheduledTimer`.
    /// - SeeAlso: ``stopPeriodicCertificateValidation()``,
    ///   ``CertificateValidator/validateServerCertificate(for:)``,
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
                    self.safeOnStatusChange(isPlaying: false, reasonKey: "status_security_failed")
                }

                #if DEBUG
                print("[DirectStreamingPlayer] [Periodic Validation] Certificate validation failed → stopping stream for URL: \(urlToValidate)")
                #endif
            }
        }
    }

    /// Invalidates and clears the periodic certificate validation timer.
    ///
    /// Safe under synchronous deallocation (no `Task` / async hop). Idempotent when
    /// no timer is scheduled.
    ///
    /// - Postcondition: ``certificateValidationTimer`` is `nil` and any prior timer is
    ///   invalidated so it cannot fire after teardown.
    /// - SeeAlso: ``startPeriodicValidation()``, ``performDeinitCleanup()``
    func stopPeriodicCertificateValidation() {
        certificateValidationTimer?.invalidate()
        certificateValidationTimer = nil
    }
}
