# SSL Certificate Pinning Challenges with iOS AVFoundation

## Overview
This document outlines the implementation of SSL certificate validation for an iOS 18 audio streaming app using AVFoundation.

## Previous Approach: Constant Pinning
- **Method**: Per-request SPKI and certificate hash pinning in `StreamingSessionDelegate`.
- **Issues**: Overly restrictive, complex transition logic, custom URL scheme workarounds.

## Current Approach: Periodic Full Certificate Validation with Transition Period
- **Method**: Centralized validation in `CertificateValidator` class, pinning the full certificate hash (`currentCertHash`). Used by `StreamingSessionDelegate` (per-request) and `DirectStreamingPlayer` (initial and periodic checks every 10 minutes).
- **Transition Period**:
  - **Dates**: 2027-01-01 00:00:00 GMT through 2027-02-10 23:59:59 GMT (end = live `*.siikkari.net` leaf `notAfter` on `livestream.siikkari.net`; start deliberately on calendar 2027-01-01). Authoritative values: `SecurityConfiguration.transitionWindowStart` / `transitionWindowEnd`. Review and update on each leaf rotation via app release.
  - **Behavior**: If runtime pin-list validation fails during this period, log a warning but trust ATS's evaluation (when leniency is still allowed), allowing a coordinated new certificate to be accepted. Transient connection issues (e.g., server reboots) should be handled as non-security errors with fallbacks to alternate servers.
  - **Outside Transition**: Strictly enforce `pinnedFingerprintDigests` before transition; fail after window end if the leaf is not on the pin list.
- **Implementation**:
  - `CertificateValidator` validates the SHA-256 hash of the certificate's DER representation, caching results for 10 minutes.
  - `StreamingSessionDelegate` uses `CertificateValidator` for trust evaluation during streaming.
  - `DirectStreamingPlayer` performs initial validation and schedules periodic HEAD requests.
- **Stream Control**:
  - Initial validation before playback.
  - Periodic checks stop the stream on failure (outside transition period), notifying via `onStatusChange`. For improved resilience, add fallback to alternate servers on transient failures before stopping.
- **ATS Compliance**: Enforced via `Info.plist` with no exceptions, handling SPKI and TLS requirements.
- **Benefits**:
  - Strong security with full certificate pinning.
  - Smooth certificate rotation during transition period.
  - Consistent validation across components.
  - Reduced complexity by removing old transition logic and custom URL schemes.
- **Considerations**:
  - Certificate rotation requires updating `currentCertHash` post-expiry.
  - ATS ensures baseline TLS security, complemented by pinned hash validation.
  - Warning logs during transition aid debugging.

## Key Considerations
- **Validation**: Full certificate pinning ensures exact certificate match, with ATS covering SPKI and chain validation.
- **Transition Period**: Allows coordinated new certificates during 2027-01-01 – 2027-02-10 GMT (see `SecurityConfiguration`), reducing user disruption at the next `*.siikkari.net` rotation.
- **Performance**: Asynchronous HEAD requests and cached results minimize overhead.
- **Maintenance**: Requires app update post-expiry with new certificate hash.
