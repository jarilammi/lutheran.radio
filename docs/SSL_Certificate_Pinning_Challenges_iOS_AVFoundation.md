# SSL Certificate Pinning Challenges with iOS AVFoundation

## Overview
This document outlines the implementation of SSL certificate validation for an iOS 18 audio streaming app using AVFoundation.

## Previous Approach: Constant Pinning
- **Method**: Per-request SPKI and certificate hash pinning in `StreamingSessionDelegate`.
- **Issues**: Overly restrictive, complex transition logic, custom URL scheme workarounds.

## Current Approach: Periodic Full Certificate Validation with Transition Period
- **Method**: Centralized validation in `CertificateValidator` class, pinning the full certificate hash (`currentCertHash`). Used by `StreamingSessionDelegate` (per-request) and `DirectStreamingPlayer` (initial and periodic checks every 10 minutes).
- **Transition Period**:
  - **Dates**: July 20, 2025, to August 20, 2025 (certificate expiry). Review and update post-expiry via app release.
  - **Behavior**: If `currentCertHash` validation fails during this period, log a warning but trust ATS's evaluation, allowing new certificates to be accepted. Transient connection issues (e.g., server reboots) should be handled as non-security errors with fallbacks to alternate servers.
  - **Outside Transition**: Strictly enforce `currentCertHash` before transition; fail after expiry if hash doesn't match.
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
- **Transition Period**: Allows new certificates during July 20–August 20, 2025, reducing user disruption.
- **Performance**: Asynchronous HEAD requests and cached results minimize overhead.
- **Maintenance**: Requires app update post-expiry with new certificate hash.
