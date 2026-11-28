//
//  BackgroundImageController.swift
//  Lutheran Radio
//
//  Encapsulates the full-bleed background image view + Core Image processing pipeline,
//  caching, low-power fast path, cold-launch and stream-switch deferral (until playback attach
//  is stable + live ICY metadata received), energy efficiency (LPM parallax removal + raw path),
//  and parallax motion effects.
//
//  For a display request that is still current, observable behavior (image choice per language,
//  filter chains for dark/light, downscaling caps, deferral timing, cross-dissolve vs immediate,
//  small-screen scaling, cache coalescing, memory warning clearing, debug output) must remain
//  pixel- and timing-identical.
//
//  Generation invariant: the controller has one desired display request. Publishing a new
//  request supersedes every earlier request, including a Core Image job that has already
//  passed the deferred flush. A superseded request may store its bitmap in the processed-image
//  cache and must not change backgroundImageView.
//
//  Owner (ViewController) supplies streams at the right moments via the public hooks and
//  performs layout (addSubview + constraints) of the vended backgroundImageView.
//  Owner retains all playback intent, streaming, and visual state decisions.
//  Paint legality is the ledger, not lastRequestedStream and not the player.
//
//  Created by Jari Lammi on 13.6.2026.
//

import UIKit
import CoreImage

/// Identity of one desired background image.
///
/// Equality includes ``generation`` and ``languageCode``. A later publish of the same
/// language code is a different request.
///
/// - Important: A view write is legal only when ``BackgroundImageDisplayLedger/mayPaint(_:)``
///   is true for the request captured at publish time.
/// - SeeAlso: ``BackgroundImageDisplayLedger``, ``BackgroundImageController``,
///   CODING_AGENT.md
struct BackgroundImageDisplayRequest: Equatable, Sendable {
    /// Monotonic id from ``BackgroundImageDisplayLedger/publish(languageCode:)``.
    /// A later publish never reuses it.
    let generation: UInt64

    /// Station language code this request wants on screen.
    let languageCode: String
}

/// Sole current background display request for ``BackgroundImageController``.
///
/// Publishing replaces the current request. ``mayPaint(_:)`` is true only for that
/// request. An older generation with the same language code does not paint.
/// The ledger does not start or cancel Core Image work.
///
/// - SeeAlso: ``BackgroundImageDisplayRequest``, ``BackgroundImageController``,
///   CODING_AGENT.md
@MainActor
struct BackgroundImageDisplayLedger {
    private var nextGeneration: UInt64 = 0
    private var current: BackgroundImageDisplayRequest?

    /// Increments the generation and installs that request as the only one that may paint.
    ///
    /// - Parameter languageCode: Station language the controller now wants on screen.
    /// - Returns: The request a view write must capture and pass to ``mayPaint(_:)``.
    /// - Postcondition: ``mayPaint(_:)`` is true for the returned value and false for every earlier publish.
    /// - SeeAlso: ``BackgroundImageController/update(for:skipCrossDissolve:)``,
    ///   ``BackgroundImageController``
    mutating func publish(languageCode: String) -> BackgroundImageDisplayRequest {
        nextGeneration &+= 1
        let request = BackgroundImageDisplayRequest(
            generation: nextGeneration,
            languageCode: languageCode
        )
        current = request
        return request
    }

    /// Whether `request` is still the sole current display request.
    ///
    /// - Parameter request: Value previously returned by ``publish(languageCode:)``.
    /// - Returns: `true` only when `request` is equal to the current publish.
    /// - SeeAlso: ``publish(languageCode:)``, ``BackgroundImageController``
    func mayPaint(_ request: BackgroundImageDisplayRequest) -> Bool {
        current == request
    }
}

/// Self-contained controller for the decorative background layer.
///
/// Owns the image view, Core Image context, processed-image cache, in-flight coalescing,
/// and the deferral state machine. One ``BackgroundImageDisplayLedger`` is the display
/// request. A job that loses that request may fill the cache and must not paint.
///
/// - SeeAlso: ``BackgroundImageDisplayLedger``, ``BackgroundImageDisplayRequest``,
///   docs/Widget-Presentation-Dataflow.md (Main-App Chrome Authority),
///   CODING_AGENT.md
@MainActor
final class BackgroundImageController {

    // MARK: - Public surface (vended view + drive methods)

    /// The background image view. Owner must add it to the hierarchy and apply the bleed constraints.
    let backgroundImageView: UIImageView

    /// Mapping of (curated) language codes to background image asset names.
    /// Languages without an entry intentionally receive a nil/cleared background.
    private let backgroundImages: [String: String] = [
        "en": "north_america",
        "de": "germany",
        "fi": "finland",
        "sv": "sweden",
        "et": "estonia"
    ]

    // MARK: - Processing & cache (internal)

    private let imageProcessingQueue = DispatchQueue(label: "radio.lutheran.imageProcessing", qos: .utility)
    private let imageProcessingContext = CIContext(options: [.useSoftwareRenderer: false])
    /// Cache for processed background images (limited to 5 — one per supported background language).
    private var processedImageCache = NSCache<NSString, UIImage>()
    /// One Core Image fill per cache key. Cleanup removes the entry only when the stored id is still that job.
    private var inFlightImageProcessing: [String: InFlightBackgroundImageJob] = [:]
    /// Monotonic id for ``InFlightBackgroundImageJob``. Independent of the display-request generation.
    private var nextInFlightImageJobID: UInt64 = 0
    private let cacheQueue = DispatchQueue(label: "radio.lutheran.imageCache", qos: .utility)

    /// One in-flight fill. Interested generations share the bitmap. Only a generation that
    /// ``BackgroundImageDisplayLedger/mayPaint(_:)`` still accepts may change the view.
    private struct InFlightBackgroundImageJob {
        let id: UInt64
        let languageCode: String
        let task: Task<UIImage?, Never>
        var interestedGenerations: Set<UInt64>
    }

    // MARK: - Display request

    /// Sole request that may paint ``backgroundImageView``.
    private var displayLedger = BackgroundImageDisplayLedger()

    // MARK: - Deferral state (cold launch + stream switch)

    /// When true, heavy CIFilter work + main-thread apply is deferred until
    /// DirectStreamingPlayer reports stable attach + has received live ICY metadata.
    /// This prevents HAL/main-thread contention on first play and early gestures.
    /// Deferral pauses the flush. It does not by itself retire the current display request.
    private var deferBackgroundImageUntilPlaybackStable = false
    private var pendingBackgroundStream: DirectStreamingPlayer.Stream?
    private var deferredBackgroundFlushTask: Task<Void, Never>?

    /// Last station a drive method was asked to show.
    ///
    /// ``scheduleDeferredForStreamSwitch(_:)`` sets this so ``updateForEnergyEfficiency()``
    /// re-enters ``update(for:skipCrossDissolve:)`` for the deferred station.
    /// During deferral that re-entry only replaces the pending stream and returns.
    /// This is not the display request: it still names the previous station through Connecting
    /// until ``scheduleDeferredForStreamSwitch(_:)`` runs.
    private var lastRequestedStream: DirectStreamingPlayer.Stream?

    // MARK: - Energy / LPM

    private var isLowEfficiencyMode: Bool {
        #if DEBUG
        if test_usesProcessedImagePath { return false }
        #endif
        return ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    // MARK: - Init

    init() {
        // Create the view exactly as it was in the monolithic VC.
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = UIColor.gray
        imageView.alpha = 0.1
        imageView.isAccessibilityElement = false
        self.backgroundImageView = imageView

        // One per supported background language (same limit as before).
        processedImageCache.countLimit = 5

        // Self-contained energy efficiency observation (power state changes).
        // The controller reacts internally using lastRequestedStream when available.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(energyEfficiencyChanged),
            name: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            object: nil
        )
    }

    deinit {
        // Selector observation does not retain the controller. Remove it before the object is gone.
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public drive API (called by ViewController at appropriate times)

    /// Publishes one display request for `stream` and paints it only while that request stays current.
    ///
    /// The publish is synchronous, before any queue hop. That includes the deferral early-return
    /// and the unknown-language clear. While deferral is active this replaces the pending stream
    /// and returns without starting Core Image. The flush's later call publishes the request that
    /// may paint for the station the flush stored.
    ///
    /// - Parameters:
    ///   - stream: Station whose background is desired.
    ///   - skipCrossDissolve: Passed through on a processed-image cache hit. The async filter
    ///     completion keeps its historical cross-dissolve so a request that is still current
    ///     does not change animation timing.
    /// - Important: A view write calls ``BackgroundImageDisplayLedger/mayPaint(_:)`` immediately
    ///   before it touches ``backgroundImageView``.
    /// - SeeAlso: ``BackgroundImageDisplayLedger``, ``scheduleDeferredForStreamSwitch(_:)``,
    ///   ``cancelPendingDeferral()``, ``BackgroundImageController``, CODING_AGENT.md
    func update(for stream: DirectStreamingPlayer.Stream, skipCrossDissolve: Bool = false) {
        let request = displayLedger.publish(languageCode: stream.languageCode)
        lastRequestedStream = stream

        if deferBackgroundImageUntilPlaybackStable {
            pendingBackgroundStream = stream
            #if DEBUG
            print("[BackgroundImageController] Background image deferred until playback attach is stable (\(stream.languageCode))")
            #endif
            return
        }

        guard let imageName = backgroundImages[stream.languageCode] else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.displayLedger.mayPaint(request) else { return }
                self.backgroundImageView.image = nil
            }
            return
        }

        let maxPixelDimension = backgroundProcessingMaxPixelDimension()
        let cacheKey = "\(imageName)_\(traitCollectionForScreen().userInterfaceStyle.rawValue)_\(Int(maxPixelDimension))"
        let isDarkMode = traitCollectionForScreen().userInterfaceStyle == .dark

        if isLowEfficiencyMode {
            // Low efficiency: Skip heavy processing/caching to save battery/CPU.
            // Load raw image directly (lightweight) and apply without filters.
            if let rawImage = UIImage(named: imageName) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.displayLedger.mayPaint(request) else { return }
                    self.backgroundImageView.image = rawImage
                    UIView.transition(with: self.backgroundImageView, duration: 0.5, options: .transitionCrossDissolve) {
                        self.backgroundImageView.image = rawImage
                    } completion: { _ in }
                }
            }
            return
        }

        // Normal mode: cache + full processing path
        cacheQueue.async { [weak self] in
            guard let self else { return }

            DispatchQueue.main.async {
                if let cachedImage = self.processedImageCache.object(forKey: cacheKey as NSString) {
                    self.applyProcessedImage(cachedImage, for: request, skipCrossDissolve: skipCrossDissolve)
                    return
                }

                self.processImageAsync(
                    imageName: imageName,
                    cacheKey: cacheKey,
                    stream: stream,
                    request: request,
                    isDarkMode: isDarkMode,
                    maxPixelDimension: maxPixelDimension
                )
            }
        }
    }

    /// Publishes `stream` as the desired background and defers Core Image until attach is stable.
    ///
    /// Also stores `stream` as the last requested stream so an energy-efficiency re-entry updates
    /// the deferred station. Cancelling the flush task does not cancel a filter job that has
    /// already started. This publish supersedes that job's request. The flush's
    /// ``update(for:skipCrossDissolve:)`` publishes the request that may paint.
    ///
    /// - Parameter stream: Station chosen while playback may still be attaching.
    /// - Postcondition: Deferral is armed. No new Core Image work starts in this call.
    /// - SeeAlso: ``update(for:skipCrossDissolve:)``, ``cancelPendingDeferral()``,
    ///   ``BackgroundImageDisplayLedger``, ``BackgroundImageController``, CODING_AGENT.md
    func scheduleDeferredForStreamSwitch(_ stream: DirectStreamingPlayer.Stream) {
        deferredBackgroundFlushTask?.cancel()
        deferredBackgroundFlushTask = nil
        deferBackgroundImageUntilPlaybackStable = true
        pendingBackgroundStream = stream
        lastRequestedStream = stream
        _ = displayLedger.publish(languageCode: stream.languageCode)
    }

    /// Called from streaming status callback when we see a "status_playing" (or equivalent)
    /// to give the HAL/ICY metadata a chance to settle before kicking off CI work.
    ///
    /// Does not publish. The ``update(for:skipCrossDissolve:)`` at the end of the flush publishes
    /// the station this call stored. Modal cancel pauses this task and does not change the
    /// desired station.
    func scheduleDeferredFlushIfNeeded() {
        guard deferBackgroundImageUntilPlaybackStable,
              let stream = pendingBackgroundStream else { return }
        guard deferredBackgroundFlushTask == nil else { return }

        deferredBackgroundFlushTask = Task { @MainActor [weak self] in
            defer { self?.deferredBackgroundFlushTask = nil }
            guard let self else { return }

            for _ in 0..<40 {
                if Task.isCancelled { return }
                if self.isDeferredBackgroundFlushReady() { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard self.isDeferredBackgroundFlushReady() else { return }

            // Brief settle after LIVE ICY before heavy CIContext + IOSurface apply.
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }

            self.deferBackgroundImageUntilPlaybackStable = false
            self.pendingBackgroundStream = nil
            #if DEBUG
            print("[BackgroundImageController] Flushing deferred background image for \(stream.languageCode)")
            #endif
            self.update(for: stream, skipCrossDissolve: true)
        }
    }

    /// Pauses the deferred flush until ``rescheduleDeferredAfterModalIfNeeded()``.
    ///
    /// Does not publish. The current display request stays paintable, including an in-flight
    /// filter for that station.
    func cancelDeferredForModalInteraction() {
        deferredBackgroundFlushTask?.cancel()
        deferredBackgroundFlushTask = nil
    }

    /// Restarts the deferred flush when a modal interaction ends and a stream is still pending.
    ///
    /// Does not publish. ``scheduleDeferredFlushIfNeeded()`` keeps the station it already stored.
    func rescheduleDeferredAfterModalIfNeeded() {
        guard deferBackgroundImageUntilPlaybackStable, pendingBackgroundStream != nil else { return }
        scheduleDeferredFlushIfNeeded()
    }

    /// Clears deferral and publishes a superseding request for the station already chosen.
    ///
    /// The following ``update(for:skipCrossDissolve:)`` publishes again. That later request is
    /// the one that may paint, so sticky pause still shows the destination without waiting for
    /// attach. This call does not start Core Image.
    ///
    /// - Postcondition: Deferral is off. Any request published before this call fails
    ///   ``BackgroundImageDisplayLedger/mayPaint(_:)``.
    /// - SeeAlso: ``update(for:skipCrossDissolve:)``, ``scheduleDeferredForStreamSwitch(_:)``,
    ///   ``BackgroundImageDisplayLedger``, ``BackgroundImageController``, CODING_AGENT.md
    func cancelPendingDeferral() {
        let languageCode = pendingBackgroundStream?.languageCode ?? lastRequestedStream?.languageCode
        deferBackgroundImageUntilPlaybackStable = false
        pendingBackgroundStream = nil
        deferredBackgroundFlushTask?.cancel()
        deferredBackgroundFlushTask = nil
        if let languageCode {
            _ = displayLedger.publish(languageCode: languageCode)
        }
    }

    /// Applies the current LPM vs normal decision to the background view (parallax on/off)
    /// and re-triggers an image update for the last known stream (if any).
    func updateForEnergyEfficiency() {
        if isLowEfficiencyMode {
            // Reduce CPU/GPU usage: Remove parallax and lower image quality
            backgroundImageView.motionEffects.forEach { backgroundImageView.removeMotionEffect($0) }
        } else {
            // Re-enable parallax if it was set up
            addParallaxToBackground()
        }
        if let stream = lastRequestedStream {
            update(for: stream)
        }
    }

    /// Clears the processed image cache (called on memory warning).
    func clearCache() {
        DispatchQueue.main.async { [weak self] in
            self?.processedImageCache.removeAllObjects()
            #if DEBUG
            print("[BackgroundImageController] Cleared processed image cache")
            #endif
        }
    }

    // MARK: - Internal helpers (moved verbatim + minor adaptation for view independence)

    private func isDeferredBackgroundFlushReady() -> Bool {
        DirectStreamingPlayer.shared.isPlaybackAttachStable()
            && DirectStreamingPlayer.shared.hasReceivedLiveStreamMetadata
    }

    /// Returns a trait collection suitable for deciding dark/light mode and scale.
    /// Uses the background view's window scene when available, falling back to current traits.
    private func traitCollectionForScreen() -> UITraitCollection {
        if let scene = backgroundImageView.window?.windowScene {
            return scene.traitCollection
        }
        return backgroundImageView.traitCollection
    }

    /// Display width (including background bleed) at 2× native scale — caps CIFilter work at display quality.
    /// Adapted to use the installed background view / its superview instead of reaching into the owning VC's view.
    private func backgroundProcessingMaxPixelDimension() -> CGFloat {
        let screenScale = backgroundImageView.window?.windowScene?.screen.scale ?? traitCollectionForScreen().displayScale
        let referenceBounds = backgroundImageView.superview?.bounds ?? backgroundImageView.bounds
        guard referenceBounds.width > 1 else {
            return ceil(393 * 2 * screenScale)
        }
        let displayWidth = referenceBounds.width + 40
        return ceil(displayWidth * 2 * screenScale)
    }

    /// Scales the image so its longest edge is at most `maxPixelDimension` before the filter chain.
    /// - Returns: Downscaled image and scale factor applied (1.0 when no downscale was needed).
    nonisolated private func downscaledForProcessing(_ image: CIImage, maxPixelDimension: CGFloat) -> (CIImage, CGFloat) {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, maxPixelDimension > 0 else {
            return (image, 1)
        }
        let longestEdge = max(extent.width, extent.height)
        guard longestEdge > maxPixelDimension else {
            return (image, 1)
        }
        let scale = maxPixelDimension / longestEdge
        return (image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), scale)
    }

    /// Starts or joins the fill for `cacheKey`.
    ///
    /// The dictionary insert happens before this method returns. The job body must not run
    /// before that insert. A coalesced caller records `request.generation` on the existing job
    /// and paints only if ``mayPaint(_:)`` still holds when the bitmap arrives.
    /// The producer's cleanup removes the entry only when the stored id is still this job.
    private func processImageAsync(
        imageName: String,
        cacheKey: String,
        stream: DirectStreamingPlayer.Stream,
        request: BackgroundImageDisplayRequest,
        isDarkMode: Bool,
        maxPixelDimension: CGFloat
    ) {
        if var existing = inFlightImageProcessing[cacheKey] {
            existing.interestedGenerations.insert(request.generation)
            inFlightImageProcessing[cacheKey] = existing
            let sharedTask = existing.task
            Task { @MainActor [weak self] in
                guard let self, let image = await sharedTask.value else { return }
                self.applyProcessedImage(image, for: request)
            }
            #if DEBUG
            print("Background image processing coalesced for \(stream.languageCode), cacheKey=\(cacheKey)")
            #endif
            return
        }

        let baseImage: UIImage?
        #if DEBUG
        if test_filterOverride != nil {
            baseImage = UIImage()
        } else {
            baseImage = UIImage(named: imageName)
        }
        #else
        baseImage = UIImage(named: imageName)
        #endif
        guard let baseImage else {
            guard displayLedger.mayPaint(request) else { return }
            backgroundImageView.image = nil
            return
        }

        nextInFlightImageJobID &+= 1
        let jobID = nextInFlightImageJobID
        let languageCode = stream.languageCode

        let task = Task<UIImage?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            defer { self.removeInFlightJob(cacheKey: cacheKey, ifIDMatches: jobID) }

            // Already on the main actor, before Core Image is enqueued. The utility queue
            // does not read the ledger. A synchronous hop from that queue back to a main
            // actor waiting on this task would deadlock.
            guard self.interestedGenerationMayPaint(cacheKey: cacheKey, jobID: jobID, languageCode: languageCode) else {
                self.removeInFlightJob(cacheKey: cacheKey, ifIDMatches: jobID)
                return nil
            }

            let finalImage = await self.renderProcessedBackgroundImage(
                baseImage: baseImage,
                languageCode: languageCode,
                isDarkMode: isDarkMode,
                maxPixelDimension: maxPixelDimension
            )

            // Cache fill is not a view write. A superseded job still stores its bitmap.
            if let finalImage {
                self.processedImageCache.setObject(finalImage, forKey: cacheKey as NSString)
            }
            return finalImage
        }

        inFlightImageProcessing[cacheKey] = InFlightBackgroundImageJob(
            id: jobID,
            languageCode: languageCode,
            task: task,
            interestedGenerations: [request.generation]
        )

        Task { @MainActor [weak self] in
            guard let self, let image = await task.value else { return }
            self.applyProcessedImage(image, for: request)
        }
    }

    /// True when this job is still the dictionary entry and any interested generation may paint.
    ///
    /// A waiter that arrived before this check is already in the set and keeps the fill alive.
    /// No interested generation means the job is abandoned.
    private func interestedGenerationMayPaint(
        cacheKey: String,
        jobID: UInt64,
        languageCode: String
    ) -> Bool {
        guard let job = inFlightImageProcessing[cacheKey], job.id == jobID else { return false }
        return job.interestedGenerations.contains { generation in
            displayLedger.mayPaint(
                BackgroundImageDisplayRequest(generation: generation, languageCode: languageCode)
            )
        }
    }

    /// Removes the fill only when `jobID` is still the entry for `cacheKey`.
    /// A newer fill for the same key keeps its entry.
    private func removeInFlightJob(cacheKey: String, ifIDMatches jobID: UInt64) {
        guard inFlightImageProcessing[cacheKey]?.id == jobID else { return }
        inFlightImageProcessing.removeValue(forKey: cacheKey)
    }

    /// Runs the filter chain, or the DEBUG bitmap substitute when a test installed one.
    ///
    /// The substitute is not a second paint policy. ``applyProcessedImage(_:for:skipCrossDissolve:)``
    /// still decides the view write.
    private func renderProcessedBackgroundImage(
        baseImage: UIImage,
        languageCode: String,
        isDarkMode: Bool,
        maxPixelDimension: CGFloat
    ) async -> UIImage? {
        #if DEBUG
        if let test_filterOverride {
            return await test_filterOverride(languageCode)
        }
        #endif

        return await withCheckedContinuation { continuation in
            self.imageProcessingQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }

                let result = autoreleasepool { () -> UIImage? in
                    guard let ciImage = CIImage(image: baseImage) else {
                        return baseImage
                    }

                    let (scaledImage, processingScale) = self.downscaledForProcessing(ciImage, maxPixelDimension: maxPixelDimension)
                    var processedImage = scaledImage

                    #if DEBUG
                    print(
                        "Processing image for \(languageCode), mode: \(isDarkMode ? "dark" : "light"), "
                            + "sourceExtent=\(ciImage.extent.integral), processingExtent=\(scaledImage.extent.integral), "
                            + "maxPx=\(Int(maxPixelDimension)), scale=\(unsafe String(format: "%.3f", processingScale))"
                    )
                    #endif

                    // Apply filters based on interface style.
                    // Methods are pure CPU transforms (no actor state) → nonisolated for Swift 6.
                    if isDarkMode {
                        processedImage = self.applyDarkModeFilters(to: processedImage, morphologyScale: processingScale)
                    } else {
                        processedImage = self.applyLightModeFilters(to: processedImage, morphologyScale: processingScale)
                    }

                    guard let cgImage = self.imageProcessingContext.createCGImage(processedImage, from: processedImage.extent) else {
                        #if DEBUG
                        print("Failed to convert CIImage to CGImage - using base image as fallback")
                        #endif
                        return baseImage
                    }

                    let converted = UIImage(cgImage: cgImage)
                    #if DEBUG
                    print("Successfully converted processed image to UIImage - size: \(converted.size)")
                    #endif
                    return converted
                }
                continuation.resume(returning: result)
            }
        }
    }

    // SAFETY / moved from ViewController: pure CPU filter chain, no shared mutable state.
    nonisolated private func applyDarkModeFilters(to image: CIImage, morphologyScale: CGFloat = 1) -> CIImage {
        var processedImage = image

        // Invert colors
        if let invertFilter = CIFilter(name: "CIColorInvert") {
            invertFilter.setValue(processedImage, forKey: kCIInputImageKey)
            if let outputImage = invertFilter.outputImage {
                processedImage = outputImage
                #if DEBUG
                print("Dark mode: Applied CIColorInvert - extent: \(processedImage.extent)")
                #endif
            }
        }

        // Adjust contrast and brightness
        if let controlsFilter = CIFilter(name: "CIColorControls") {
            controlsFilter.setValue(processedImage, forKey: kCIInputImageKey)
            controlsFilter.setValue(1.3, forKey: kCIInputContrastKey)
            controlsFilter.setValue(0.2, forKey: kCIInputBrightnessKey)
            if let outputImage = controlsFilter.outputImage {
                processedImage = outputImage
                #if DEBUG
                print("Dark mode: Applied CIColorControls - extent: \(processedImage.extent)")
                #endif
            }
        }

        // Morphology (radius scaled to match visual effect after pre-filter downscale)
        if let dilateFilter = CIFilter(name: "CIMorphologyMaximum") {
            dilateFilter.setValue(processedImage, forKey: kCIInputImageKey)
            dilateFilter.setValue(4.0 * morphologyScale, forKey: kCIInputRadiusKey)
            if let outputImage = dilateFilter.outputImage {
                processedImage = outputImage
                #if DEBUG
                print("Dark mode: Applied CIMorphologyMaximum - extent: \(processedImage.extent)")
                #endif
            }
        }

        return processedImage
    }

    // SAFETY / moved from ViewController: pure CPU filter chain, no shared mutable state.
    nonisolated private func applyLightModeFilters(to image: CIImage, morphologyScale: CGFloat = 1) -> CIImage {
        var processedImage = image

        // Color controls
        if let controlsFilter = CIFilter(name: "CIColorControls") {
            controlsFilter.setValue(processedImage, forKey: kCIInputImageKey)
            controlsFilter.setValue(1.3, forKey: kCIInputContrastKey)
            controlsFilter.setValue(-0.2, forKey: kCIInputBrightnessKey)
            if let outputImage = controlsFilter.outputImage {
                processedImage = outputImage
                #if DEBUG
                print("Light mode: Applied CIColorControls - extent: \(processedImage.extent)")
                #endif
            }
        }

        // Morphology operations (radius scaled to match visual effect after pre-filter downscale)
        if let dilateFilter = CIFilter(name: "CIMorphologyMaximum") {
            dilateFilter.setValue(processedImage, forKey: kCIInputImageKey)
            dilateFilter.setValue(5.0 * morphologyScale, forKey: kCIInputRadiusKey)
            if let outputImage = dilateFilter.outputImage {
                processedImage = outputImage
                #if DEBUG
                print("Light mode: Applied CIMorphologyMaximum - extent: \(processedImage.extent)")
                #endif
            }
        }

        if let erodeFilter = CIFilter(name: "CIMorphologyMinimum") {
            erodeFilter.setValue(processedImage, forKey: kCIInputImageKey)
            erodeFilter.setValue(1.0 * morphologyScale, forKey: kCIInputRadiusKey)
            if let outputImage = erodeFilter.outputImage {
                processedImage = outputImage
                #if DEBUG
                print("Light mode: Applied CIMorphologyMinimum - extent: \(processedImage.extent)")
                #endif
            }
        }

        return processedImage
    }

    /// Assigns a processed bitmap when `request` is still the current display request.
    ///
    /// Cache hits and finished filter jobs both come here. The check is the last read
    /// before any mutation of ``backgroundImageView``.
    private func applyProcessedImage(
        _ image: UIImage,
        for request: BackgroundImageDisplayRequest,
        skipCrossDissolve: Bool = false
    ) {
        #if DEBUG
        test_applyProcessedImageEntries += 1
        #endif
        guard displayLedger.mayPaint(request) else { return }

        // This runs on main thread
        let screen = backgroundImageView.window?.windowScene?.screen
        let screenSize = screen?.bounds.size ?? CGSize(width: 375, height: 667) // Fallback to default iPhone size if nil
        let isSmallScreen = screenSize.height < 1600
        let targetAlpha: CGFloat = traitCollectionForScreen().userInterfaceStyle == .dark ? 0.3 : 0.15

        if isSmallScreen {
            let imageSize = image.size
            let screenAspect = screenSize.width / screenSize.height
            let imageAspect = imageSize.width / imageSize.height
            let scaleFactor = min(0.85, screenAspect / imageAspect)
            backgroundImageView.transform = CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)
        } else {
            backgroundImageView.transform = .identity
        }

        if skipCrossDissolve {
            backgroundImageView.image = image
            backgroundImageView.alpha = targetAlpha
            addParallaxToBackground()
            #if DEBUG
            print("Background update completed - alpha: \(backgroundImageView.alpha), image: \(backgroundImageView.image != nil ? "set" : "nil")")
            #endif
            return
        }

        backgroundImageView.image = image
        addParallaxToBackground()

        UIView.transition(with: backgroundImageView, duration: 0.5, options: .transitionCrossDissolve, animations: {
            self.backgroundImageView.alpha = targetAlpha
        }, completion: { _ in
            #if DEBUG
            print("Background update completed - alpha: \(self.backgroundImageView.alpha), image: \(self.backgroundImageView.image != nil ? "set" : "nil")")
            #endif
        })
    }

    private func addParallaxToBackground() {
        backgroundImageView.addParallaxEffect(intensity: 10.0)
    }

    @objc private func energyEfficiencyChanged() {
        updateForEnergyEfficiency()
    }

    // MARK: - DEBUG test seam

    #if DEBUG
    /// When true, tests stay on the processed-image path while Low Power Mode is on.
    /// Production leaves this false. It does not decide whether a request may paint.
    var test_usesProcessedImagePath = false

    /// Replaces the Core Image filter block with a caller-supplied bitmap.
    ///
    /// The interest check, cache store, id-matched cleanup, and ``mayPaint(_:)`` gate stay
    /// on the production path. `nil` runs Core Image.
    var test_filterOverride: (@MainActor (String) async -> UIImage?)?

    /// Fills currently in ``inFlightImageProcessing``.
    var test_inFlightImageJobCount: Int { inFlightImageProcessing.count }

    /// Entries into ``applyProcessedImage(_:for:skipCrossDissolve:)``, including requests
    /// ``mayPaint(_:)`` rejects. Observation only.
    var test_applyProcessedImageEntries = 0

    /// Generations recorded on the in-flight fill for `languageCode`, or zero when none exists.
    func test_interestedGenerationCount(for languageCode: String) -> Int {
        inFlightImageProcessing.values.first { $0.languageCode == languageCode }?.interestedGenerations.count ?? 0
    }
    #endif
}

// MARK: - Parallax Effect Extension (moved with the background feature)
// Extends UIView with device motion-based parallax effects.
// Only the background image view uses this in the current architecture.
extension UIView {
    /// Adds horizontal and vertical tilt effects for a 3D-like appearance.
    /// - Parameter intensity: Magnitude of the tilt (e.g., 10.0 for subtle effect).
    /// - Note: Removes existing effects first to prevent conflicts.
    func addParallaxEffect(intensity: CGFloat) {
        // Remove any existing motion effects to avoid conflicts
        motionEffects.forEach { removeMotionEffect($0) }

        // Horizontal tilt effect
        let horizontalMotion = UIInterpolatingMotionEffect(
            keyPath: "center.x",
            type: .tiltAlongHorizontalAxis
        )
        horizontalMotion.minimumRelativeValue = -intensity
        horizontalMotion.maximumRelativeValue = intensity

        // Vertical tilt effect
        let verticalMotion = UIInterpolatingMotionEffect(
            keyPath: "center.y",
            type: .tiltAlongVerticalAxis
        )
        verticalMotion.minimumRelativeValue = -intensity
        verticalMotion.maximumRelativeValue = intensity

        // Group the effects
        let motionGroup = UIMotionEffectGroup()
        motionGroup.motionEffects = [horizontalMotion, verticalMotion]

        // Apply to the view
        addMotionEffect(motionGroup)
    }
}
