# Widget & Live Activity Presentation Dataflow

This document is the concise, permanent reference for how Lutheran Radio derives and consumes presentation data for WidgetKit home-screen widgets and ActivityKit Live Activities (Dynamic Island + Lock Screen).

It complements (and is cross-referenced by) the source headers in `LutheranRadioWidget.swift`, `LutheranRadioWidgetLiveActivity.swift`, `WidgetDisplayModels.swift`, and `PlayerVisualState.swift`, as well as `CODING_AGENT.md`.

## Snapshot-Driven Model

WidgetKit and ActivityKit deliver **frozen value-type snapshots** across process boundaries:

- **Home widgets**: `Provider` (conforming to `AppIntentTimelineProvider`) produces `SimpleEntry` values. The system compares `TimelineEntry` fields to decide re-evaluation.
- **Live Activities**: `RadioLiveActivityManager` pushes `LutheranRadioLiveActivityAttributes.ContentState` (containing `visualState` + `streamMetadata`). The system renders via `ActivityConfiguration` closures and `LockScreenLiveActivityView`.

There are no live `@Observable` objects inside the widget extension. All display decisions are computed from the snapshot at derivation time or consumption time.

## The Three Narrow Presentation Surfaces

All presentation is organized into three narrow, `Equatable` value types derived from the authoritative `PlayerVisualState` (plus optional `StreamProgramMetadata`):

| Surface                        | Type                              | Mapper / Resolver                              | What it carries                          | Consumers |
|--------------------------------|-----------------------------------|------------------------------------------------|------------------------------------------|-----------|
| Status indicator               | `PlayerStatusPresentation`        | `visualState.makeStatusPresentation()`         | `background`, `foreground`, `text`, `systemImage?` | Status text, pills, indicators in widgets + LA + Control widget |
| Primary play/pause control     | `PlayerControlPresentation`       | `visualState.makeControlPresentation()`        | `systemImage` ("play.fill"/"pause.fill"), `tint: Color` | Play/pause buttons (Small/Medium/Large, DI trailing/compactTrailing, Lock Screen row, Control widget) |
| Metadata / emphasis (title + speaker) | `WidgetNowPlayingDisplayModel` | `widgetNowPlayingDisplayModel(visualState:streamMetadata:languageName:)` | `programTitle`, `speakerLine`, `speakerVisible`, `emphasis: WidgetMetadataEmphasis` | `WidgetMetadataRegion`, DI center/compactLeading, Lock Screen metadata blocks |

**Derivation rule (snapshot-driven):**

- **Widgets**: All three are computed **once per entry** inside the `Provider` (`placeholder`, `snapshot`, `timeline` / `createEntry`) and stored directly on `SimpleEntry`. Leaf views read the narrow properties.
- **Live Activities**: The three are computed **once at the top of `LockScreenLiveActivityView.body`** and **once inside the outer `dynamicIsland` closure**, then closed over by the region builders and subviews. No repeated derivation inside individual `.leading`/`.center`/etc. blocks for the presentation concerns.

`WidgetMetadataRegion` is deliberately narrow: it receives only a `WidgetNowPlayingDisplayModel`.

## Why Pre-Derivation Matters

- **Invalidation cost**: WidgetKit performs structural comparison on the `TimelineEntry`. A change to an unrelated field (e.g. `configuration` or full `availableStreams` ordering) should not force re-work in a leaf that only renders the play glyph. Carrying the already-derived narrow value shrinks the set of mutations that cause body re-evaluation for that leaf.
- **Region work in ActivityKit**: Dynamic Island regions are independent. Re-deriving title/speaker or control glyph inside every region multiplies work on every push. One computation at the outer closure is bounded.
- **View simplicity**: Leaf views and region closures become trivial — they render exactly the four (or two) fields they need. No `switch`, no fallback logic, no `Color(uiColor:)` bridging inside bodies.
- **Consistency**: The same mapping rules apply to main-app UI (via `PlayerViewModel`), home widgets, Live Activities, and Control widgets because the mappers live on `PlayerVisualState` (or the dedicated resolver in WidgetDisplayModels).

## Semantic vs. Presentation Uses of PlayerVisualState

`PlayerVisualState` still exposes:
- `isActivelyPlaying` (purely `self == .playing`)
- `buttonTintColor` (and legacy `backgroundColor` / `textColor`)

**Policy**: These remain the source of truth for **semantic** decisions:
- Presence of the red LIVE indicator and animation bars
- "Local Only" label vs. bars
- Resurrection / intent logic
- Decorative radio glyph tint in certain LA regions (non-control)

Pure play/pause glyph choice and tint for **controls** must use `makeControlPresentation()`.

See the header of `PlayerVisualState.swift` for the exact division and AGENT NOTE.

## Adding or Changing a Presentation Axis (Guidance for Contributors)

1. Decide whether the concern belongs on one of the existing surfaces or needs a new narrow type (prefer adding a new `...Presentation` or `...DisplayModel` struct).
2. Implement (or extend) the pure mapper on `PlayerVisualState` or as a free function in `WidgetDisplayModels.swift`.
3. Update derivation sites:
   - Add the new field to `SimpleEntry`.
   - Compute it once in `Provider.placeholder`, `createEntry`, and `timeline`.
   - Compute it once at the top of `LockScreenLiveActivityView.body` and inside the outer `dynamicIsland` closure (if applicable).
4. Change consumers (family views, regions, LA region closures, Control widget) to read only the narrow value.
5. Update `SimpleEntry` property documentation and the three main widget/LA files' headers.
6. Add or update an entry in the table above.
7. Update this document, the relevant `///` headers (with `- SeeAlso:`), and `PlayerVisualState.swift` header if the division of concerns changed.
8. Verify with the preview matrix in `LutheranRadioWidget.swift` and on-device widget/LA surfaces.

Never derive presentation inside leaf view `body` for the three canonical surfaces. Never duplicate the mapping rules.

## Cross-References

- `PlayerVisualState.swift` — authoritative source of `makeStatusPresentation()` / `makeControlPresentation()` + semantics of `isActivelyPlaying`.
- `WidgetDisplayModels.swift` — SSOT + resolver for `WidgetNowPlayingDisplayModel` + language/flag helpers.
- `LutheranRadioWidget.swift` — `SimpleEntry`, `Provider`, family views, `WidgetMetadataRegion`.
- `LutheranRadioWidgetLiveActivity.swift` — `LutheranRadioLiveActivityWidget`, `LockScreenLiveActivityView`, Dynamic Island regions, intents.
- `LutheranRadioWidgetControl.swift` — Control widget usage of the same mappers.
- `CODING_AGENT.md` — Documentation & Comment Standards, Single Source of Truth Principles, cross-target shared files.
- `docs/widget-liveactivity-presentation-dataflow-analysis.md` — detailed pre-refactor analysis (historical context).

All user-visible strings use `String(localized: "...", table: "Localizable")`.

## See Also

- `README.md` (Single Sources of Truth section)
- `<doc:Architecture>` (in the Core DocC catalog)