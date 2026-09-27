## 0.2.0

- Every surface draws the brand's design. The dashboard's Design editor saves a philosophy and a few knobs; the session carries them resolved into light and dark tokens (`GraineSessionConfig.design`), and the bar, the components and the loader draw those tokens as `contract/DESIGN.md` describes — colours, type, corners, outlines, shadows (or the solid offset), glass, bubble style and motion. The SDK never resolves a philosophy itself, so a new one needs no release. Without a design (an older server), everything looks exactly as before.
- `GraineLauncher`: the floating button, in the design's shape (circle, squircle with continuous corners, rounded square, square or pill), accent and glyph — or the brand's logo, else the first letter. The glyph is drawn from its SVG path, so it is on screen in the first frame, offline included.
- `GraineInApp.design` and `.theme` (the tokens for the device's current light or dark, picked again when it switches), `GraineListener.onTheme`, and `GraineGlyph.url` for an app that draws its own launcher from the glyph image.
- `GraineConfig.fonts` maps a design font family to the name the app bundles it under. A family the app does not bundle is drawn in the system font, silently.
- Motion follows the design's duration and easing, and the system's Reduce Motion always wins.

## 0.1.1

- Back in the foreground, an idle engine is told to warm (`graine:warm`). The engine keeps a SIP registration warm so a tap costs only the call itself, but a phone drops that idle connection while the app is in the background, and the engine page is not reliably told by its own web view. The SDK now says so when the app returns — only when the page is ready, never during a call.
- Connecting is faster in the hosted engine itself — a warm tap connects in about 0.2 s — with no change to this package.

## 0.1.0

First release.

- `GraineInApp` and `GraineVoice` host Graine's voice engine in a Swift package.
- Screen context, prompt variables and in-app actions, masked on the device before anything leaves it.
- Components the agent draws, the loader, the draggable keyboard-aware bar, friction detection and connection quality.
- Tested against the same contract as the React Native, Android and Flutter SDKs.
