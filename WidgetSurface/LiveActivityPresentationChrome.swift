//
//  LiveActivityPresentationChrome.swift
//  WidgetSurface
//
//  Created by Jari Lammi on 24.7.2026.
//
//  Shared Live Activity layout chrome: metadata block, language row, equalizer bars.
//  Presentation-only — no security logic (see Core/). Does not import SharedPlayerManager
//  or AppIntents; callers wrap chips in Button(intent:) at the extension boundary.
//
//  Why this file exists: Dynamic Island expanded regions and Lock Screen Live Activity
//  previously duplicated title/speaker frames, language flag+name rows, and equalizer
//  bars. Centralizing those pure layout pieces keeps sizing contracts aligned and
//  removes non-deterministic bar heights from the presentation tree.
//
//  - SeeAlso: ``WidgetNowPlayingDisplayModel``, ``alternativeStreamCodes(current:availableLanguageCodes:maxCount:fallbackCodes:)``,
//    docs/Widget-Presentation-Dataflow.md, docs/Widget-Functionality-Roadmap.md,
//    CODING_AGENT.md (WidgetSurface surface area).
//

import SwiftUI

// MARK: - Metadata block

/// Size tokens for Live Activity title + speaker slots (fixed-height contract).
///
/// Dynamic Island center and Lock Screen share the same min/max frame heights so
/// ICY metadata updates never insert or remove rows. Font weight differs slightly
/// by surface for readability inside each system card.
public enum LiveActivityMetadataLayout: Sendable, Equatable {
    /// Dynamic Island expanded `.center` region.
    case dynamicIsland
    /// Lock Screen Live Activity card.
    case lockScreen

    var titleFont: Font {
        switch self {
        case .dynamicIsland: .system(size: 10, weight: .semibold)
        case .lockScreen: .footnote.weight(.semibold)
        }
    }

    var speakerFont: Font {
        switch self {
        case .dynamicIsland: .system(size: 9)
        case .lockScreen: .caption2
        }
    }

    var titleMinimumScaleFactor: CGFloat {
        switch self {
        case .dynamicIsland: 0.85
        case .lockScreen: 0.75
        }
    }

    var titleMinHeight: CGFloat { 18 }
    var titleMaxHeight: CGFloat { 22 }
    var speakerMinHeight: CGFloat { 12 }
    var speakerMaxHeight: CGFloat { 14 }
}

/// Fixed-height program title + speaker lines for Live Activity surfaces.
///
/// Receives a pre-derived ``WidgetNowPlayingDisplayModel`` only. Does not read
/// `PlayerVisualState` or raw `StreamProgramMetadata`.
///
/// - Important: Keep the fixed min/max frame contract. Conditional row insertion
///   destabilizes Dynamic Island and Lock Screen layout under ICY churn.
/// - SeeAlso: ``WidgetNowPlayingDisplayModel``, ``LiveActivityMetadataLayout``.
public struct LiveActivityMetadataBlock: View {
    public let model: WidgetNowPlayingDisplayModel
    public let layout: LiveActivityMetadataLayout

    public init(model: WidgetNowPlayingDisplayModel, layout: LiveActivityMetadataLayout) {
        self.model = model
        self.layout = layout
    }

    public var body: some View {
        VStack(spacing: 2) {
            Text(model.programTitle)
                .font(layout.titleFont)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(layout.titleMinimumScaleFactor)
                .truncationMode(.tail)
                .opacity(model.emphasis.opacity)
                .frame(
                    maxWidth: .infinity,
                    minHeight: layout.titleMinHeight,
                    maxHeight: layout.titleMaxHeight,
                    alignment: .center
                )

            Text(model.speakerLine)
                .font(layout.speakerFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(model.speakerVisible ? model.emphasis.opacity : 0)
                .frame(
                    maxWidth: .infinity,
                    minHeight: layout.speakerMinHeight,
                    maxHeight: layout.speakerMaxHeight,
                    alignment: .center
                )
        }
    }
}

// MARK: - Language chrome

/// Compact flag + localized language name for Live Activity headers and leading regions.
///
/// - SeeAlso: ``displayFlag(for:)``, ``displayLanguageName(for:preferredStreamLanguage:)``.
public struct LiveActivityLanguageLabel: View {
    public let flag: String
    public let name: String
    public let flagFont: Font
    public let nameFont: Font
    public let spacing: CGFloat

    public init(
        flag: String,
        name: String,
        flagFont: Font = .caption2,
        nameFont: Font = .caption2,
        spacing: CGFloat = 4
    ) {
        self.flag = flag
        self.name = name
        self.flagFont = flagFont
        self.nameFont = nameFont
        self.spacing = spacing
    }

    /// Convenience using pure WidgetSurface language helpers.
    public init(
        languageCode: String,
        preferredStreamLanguage: String? = nil,
        flagFont: Font = .caption2,
        nameFont: Font = .caption2,
        spacing: CGFloat = 4
    ) {
        self.init(
            flag: displayFlag(for: languageCode),
            name: displayLanguageName(for: languageCode, preferredStreamLanguage: preferredStreamLanguage),
            flagFont: flagFont,
            nameFont: nameFont,
            spacing: spacing
        )
    }

    public var body: some View {
        HStack(spacing: spacing) {
            Text(flag)
                .font(flagFont)
            Text(name)
                .font(nameFont)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Vertical flag + name chip content for Live Activity stream-switch buttons.
///
/// Extension views wrap this in `Button(intent: LiveActivitySwitchStreamIntent(...))`.
/// The chip itself is presentation-only so WidgetSurface never depends on AppIntents.
public struct LiveActivityStreamSwitchChipLabel: View {
    public let flag: String
    public let name: String
    public let nameFont: Font
    public let showsBackground: Bool

    public init(
        flag: String,
        name: String,
        nameFont: Font = .system(size: 8, weight: .medium),
        showsBackground: Bool = true
    ) {
        self.flag = flag
        self.name = name
        self.nameFont = nameFont
        self.showsBackground = showsBackground
    }

    public init(
        languageCode: String,
        preferredStreamLanguage: String? = nil,
        nameFont: Font = .system(size: 8, weight: .medium),
        showsBackground: Bool = true
    ) {
        self.init(
            flag: displayFlag(for: languageCode),
            name: displayLanguageName(for: languageCode, preferredStreamLanguage: preferredStreamLanguage),
            nameFont: nameFont,
            showsBackground: showsBackground
        )
    }

    public var body: some View {
        VStack(spacing: 2) {
            Text(flag)
                .font(.system(size: 16))
            Text(name)
                .font(nameFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, showsBackground ? 8 : 0)
        .padding(.vertical, showsBackground ? 4 : 0)
        .background(showsBackground ? Color.gray.opacity(0.1) : Color.clear)
        .cornerRadius(showsBackground ? 8 : 0)
    }
}

// MARK: - Equalizer bars (deterministic)

/// Decorative equalizer bar geometry for Live Activity playing chrome.
///
/// Heights and animation durations are **fixed per bar index** so previews, snapshots,
/// and on-device frames are deterministic (no `CGFloat.random` / `Double.random`).
public enum LiveActivityEqualizerStyle: Sendable, Equatable {
    /// Expanded Dynamic Island trailing (3 bars).
    case expandedTrailing
    /// Expanded Dynamic Island bottom (5 bars, gradient fill).
    case expandedBottom
    /// Compact leading (2 bars).
    case compactLeading

    public var barCount: Int {
        switch self {
        case .expandedTrailing: 3
        case .expandedBottom: 5
        case .compactLeading: 2
        }
    }

    public var barWidth: CGFloat {
        switch self {
        case .expandedTrailing: 2
        case .expandedBottom: 2
        case .compactLeading: 1
        }
    }

    public var spacing: CGFloat {
        switch self {
        case .expandedTrailing: 2
        case .expandedBottom: 1
        case .compactLeading: 1
        }
    }

    public var cornerRadius: CGFloat {
        switch self {
        case .expandedTrailing: 1
        case .expandedBottom, .compactLeading: 0.5
        }
    }

    /// Fixed heights (points) indexed by bar position.
    public func height(at index: Int) -> CGFloat {
        switch self {
        case .expandedTrailing:
            let heights: [CGFloat] = [6, 12, 8]
            return heights[index % heights.count]
        case .expandedBottom:
            let heights: [CGFloat] = [4, 8, 10, 6, 9]
            return heights[index % heights.count]
        case .compactLeading:
            let heights: [CGFloat] = [3, 5]
            return heights[index % heights.count]
        }
    }

    /// Fixed ease-in-out duration (seconds) indexed by bar position.
    public func duration(at index: Int) -> Double {
        switch self {
        case .expandedTrailing:
            let durations = [0.45, 0.55, 0.40]
            return durations[index % durations.count]
        case .expandedBottom:
            let durations = [0.40, 0.50, 0.60, 0.45, 0.55]
            return durations[index % durations.count]
        case .compactLeading:
            return 0.5
        }
    }

    public var usesGradient: Bool {
        self == .expandedBottom
    }

    public var staggeredDelay: Double {
        switch self {
        case .expandedBottom: 0.1
        case .expandedTrailing, .compactLeading: 0
        }
    }
}

/// Deterministic equalizer bars shown while Live Activity content is actively playing.
///
/// - Parameters:
///   - style: Bar count, fixed heights, and animation cadence.
///   - isPlaying: Animation value; bars are typically gated by the caller with `if isPlaying`.
/// - SeeAlso: ``LiveActivityEqualizerStyle``.
public struct LiveActivityEqualizerBars: View {
    public let style: LiveActivityEqualizerStyle
    public let isPlaying: Bool

    public init(style: LiveActivityEqualizerStyle, isPlaying: Bool) {
        self.style = style
        self.isPlaying = isPlaying
    }

    public var body: some View {
        HStack(spacing: style.spacing) {
            ForEach(0..<style.barCount, id: \.self) { index in
                bar(at: index)
                    .frame(width: style.barWidth, height: style.height(at: index))
                    .animation(
                        .easeInOut(duration: style.duration(at: index))
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * style.staggeredDelay),
                        value: isPlaying
                    )
            }
        }
    }

    @ViewBuilder
    private func bar(at index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius)
        if style.usesGradient {
            shape.fill(
                LinearGradient(
                    gradient: Gradient(colors: [.green, .blue]),
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
        } else {
            shape.fill(Color.green)
        }
    }
}

// MARK: - Control chrome helpers

/// Circle-variant SF Symbol for Lock Screen play/pause weight.
///
/// Derives purely from the narrow ``PlayerControlPresentation`` base glyph
/// (`play.fill` / `pause.fill`) without re-reading `PlayerVisualState`.
///
/// - Parameter systemImage: Base control glyph from ``PlayerControlPresentation/systemImage``.
/// - Returns: `"pause.circle.fill"` or `"play.circle.fill"`.
public func liveActivityLockScreenControlSystemImage(from systemImage: String) -> String {
    systemImage == "pause.fill" ? "pause.circle.fill" : "play.circle.fill"
}
