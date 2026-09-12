# ``Lutheran_Radio``

Lutheran Radio is a security-first iOS streaming application for Lutheran Radio, with UI in 50 languages and five playback streams (en, de, fi, sv, et).

## Overview

This target owns the player UI, the ``DirectStreamingPlayer`` audio-engine façade, ``SharedPlayerManager`` (playback intent, `PersistedWidgetState`, and `PlayerEvent` emission), Live Activity lifecycle via ``RadioLiveActivityManager``, and widget intent execution.

Security policy, DNS TXT validation, and certificate pinning live only in `Core`. This target consumes that policy and does not duplicate it; read the `Core` overview for the invariants.

Widget and Live Activity presentation — visual state, planners, timeline blueprints, and chrome — lives in `WidgetSurface`. This module must not import security into `WidgetSurface` or duplicate those presentation types.

`PlayerEvent` emission from ``SharedPlayerManager`` is additive and non-forcing. Engine mutation and snapshot writes remain primary.

## Topics

### Playback and session

- ``SharedPlayerManager``
- ``DirectStreamingPlayer``
- ``RadioPlayerCoordinator``

### UI

- ``ViewController``
- ``RadioPlayerView``
- ``PlayerViewModel``

### Live Activity and widgets

- ``RadioLiveActivityManager``
- ``WidgetRefreshManager``
- ``WidgetIntentExecution``

## See Also

- [Security Model Validation](https://github.com/jarilammi/lutheran.radio/blob/HEAD/README.md#security-model-validation)
- [Certificate Pinning](https://github.com/jarilammi/lutheran.radio/blob/HEAD/README.md#certificate-pinning)
- [Single Sources of Truth](https://github.com/jarilammi/lutheran.radio/blob/HEAD/README.md#single-sources-of-truth--key-files-agents-must-know-intimately)
- [Widget Presentation Dataflow](https://github.com/jarilammi/lutheran.radio/blob/HEAD/docs/Widget-Presentation-Dataflow.md)
- [Live Activity Stacking and Media Surfaces](https://github.com/jarilammi/lutheran.radio/blob/HEAD/docs/Live-Activity-Stacking-and-Media-Surfaces.md)
- [CODING_AGENT.md](https://github.com/jarilammi/lutheran.radio/blob/HEAD/CODING_AGENT.md)
