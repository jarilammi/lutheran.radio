//
//  BackgroundImageController.swift
//  Lutheran Radio
//
//  Encapsulates the full-bleed background image view + Core Image processing pipeline,
//  caching, low-power fast path, cold-launch and stream-switch deferral (until playback attach
//  is stable + live ICY metadata received), energy efficiency (LPM parallax removal + raw path),
//  and parallax motion effects.
//
//  All observable behavior (image choice per language, filter chains for dark/light, downscaling
//  caps, deferral timing, cross-dissolve vs immediate, small-screen scaling, cache coalescing,
//  memory warning clearing, debug output) must remain pixel- and timing-identical.
//
//  Owner (ViewController) supplies streams at the right moments via the public hooks and
//  performs layout (addSubview + constraints) of the vended backgroundImageView.
//  Owner retains all playback intent, streaming, and visual state decisions.
//
//  Created by Jari Lammi on 13.6.2026.
//

import UIKit
import CoreImage

/// Self-contained controller for the decorative background layer.
/// - Owns the UIImageView (full-bleed with negative insets for parallax bleed).
/// - Owns all CIContext, queues, NSCache, in-flight task coalescing, and deferral state machine.
/// - Drives low-efficiency (raw image, no filters, no parallax) vs normal processed path.
/// - Exposes narrow API for the orchestrator to call at the correct lifecycle points.
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
    /// Coalesces overlapping processing work for the same cache key.
    private var inFlightImageProcessing: [String: Task<UIImage?, Never>] = [:]
    private let cacheQueue = DispatchQueue(label: "radio.lutheran.imageCache", qos: .utility)

    // MARK: - Deferral state (cold launch + stream switch)

    /// When true, heavy CIFilter work + main-thread apply is deferred until
    /// DirectStreamingPlayer reports stable attach + has received live ICY metadata.
    /// This prevents HAL/main-thread contention on first play and early gestures.
    private var deferBackgroundImageUntilPlaybackStable = false
    private var pendingBackgroundStream: DirectStreamingPlayer.Stream?
    private var deferredBackgroundFlushTask: Task<Void, Never>?

    /// Remembers the last stream we were asked to display so that energy-efficiency
    /// changes (LPM on/off) can re-apply the correct image without requiring the
    /// owner to pass the stream on every notification.
    private var lastRequestedStream: DirectStreamingPlayer.Stream?

    // MARK: - Energy / LPM

    private var isLowEfficiencyMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
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

    // MARK: - Public drive API (called by ViewController at appropriate times)

    /// Primary entry point. Respects any active deferral, low-efficiency mode, cache, and performs
    /// async CI processing + cross-dissolve (or immediate) apply when appropriate.
    func update(for stream: DirectStreamingPlayer.Stream, skipCrossDissolve: Bool = false) {
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
                self?.backgroundImageView.image = nil
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
                    guard let self = self else { return }
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
            guard let self = self else { return }

            DispatchQueue.main.async {
                if let cachedImage = self.processedImageCache.object(forKey: cacheKey as NSString) {
                    self.applyProcessedImage(cachedImage, for: stream, skipCrossDissolve: skipCrossDissolve)
                    return
                }

                self.processImageAsync(
                    imageName: imageName,
                    cacheKey: cacheKey,
                    stream: stream,
                    isDarkMode: isDarkMode,
                    maxPixelDimension: maxPixelDimension
                )
            }
        }
    }

    /// Called on language selection / stream switch while playback may be active.
    /// Defers the heavy work for the *new* stream until attach is stable.
    func scheduleDeferredForStreamSwitch(_ stream: DirectStreamingPlayer.Stream) {
        deferredBackgroundFlushTask?.cancel()
        deferredBackgroundFlushTask = nil
        deferBackgroundImageUntilPlaybackStable = true
        pendingBackgroundStream = stream
    }

    /// Called from streaming status callback when we see a "status_playing" (or equivalent)
    /// to give the HAL/ICY metadata a chance to settle before kicking off CI work.
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

    func cancelDeferredForModalInteraction() {
        deferredBackgroundFlushTask?.cancel()
        deferredBackgroundFlushTask = nil
    }

    func rescheduleDeferredAfterModalIfNeeded() {
        guard deferBackgroundImageUntilPlaybackStable, pendingBackgroundStream != nil else { return }
        scheduleDeferredFlushIfNeeded()
    }

    /// Explicitly clears any active deferral state and tasks (used in userPaused early-return
    /// paths during stream switch so we can immediately show the background for the new stream).
    func cancelPendingDeferral() {
        deferBackgroundImageUntilPlaybackStable = false
        pendingBackgroundStream = nil
        deferredBackgroundFlushTask?.cancel()
        deferredBackgroundFlushTask = nil
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

    /// Processes and applies background image filters asynchronously.
    private func processImageAsync(
        imageName: String,
        cacheKey: String,
        stream: DirectStreamingPlayer.Stream,
        isDarkMode: Bool,
        maxPixelDimension: CGFloat
    ) {
        if let inFlight = inFlightImageProcessing[cacheKey] {
            Task { @MainActor [weak self] in
                guard let self, let image = await inFlight.value else { return }
                self.applyProcessedImage(image, for: stream)
            }
            #if DEBUG
            print("Background image processing coalesced for \(stream.languageCode), cacheKey=\(cacheKey)")
            #endif
            return
        }

        guard let baseImage = UIImage(named: imageName) else {
            backgroundImageView.image = nil
            return
        }

        let task = Task<UIImage?, Never> { @MainActor [weak self] in
            guard let self else { return nil }

            let finalImage: UIImage? = await withCheckedContinuation { continuation in
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
                            "Processing image for \(stream.languageCode), mode: \(isDarkMode ? "dark" : "light"), "
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

            defer { self.inFlightImageProcessing.removeValue(forKey: cacheKey) }

            if let finalImage {
                self.processedImageCache.setObject(finalImage, forKey: cacheKey as NSString)
            }
            return finalImage
        }

        inFlightImageProcessing[cacheKey] = task

        Task { @MainActor [weak self] in
            guard let self, let image = await task.value else { return }
            self.applyProcessedImage(image, for: stream)
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

    private func applyProcessedImage(
        _ image: UIImage,
        for stream: DirectStreamingPlayer.Stream,
        skipCrossDissolve: Bool = false
    ) {
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
