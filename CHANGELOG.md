## 0.5.0

- A connect that says where it is. The engine now reports a connect's stage (`graine:progress`: registering, dialling, retrying, switching, failed — `contract/DESIGN.md`, "Connecting"). The voice bar draws a retry, or a move to the other transport, as the loader's "reconnecting" moment in the brand's own words; after 4 s of waiting on a connect it says "Still connecting…" — but only while the brand's connecting words are the default "Connecting…": a wording the brand chose, often not English, is never replaced. When nothing could carry the call it says "Couldn’t connect · tap to retry", and the microphone (or a tap on the status) places a new call. A stage this build does not know is ignored.
- `GraineVoice.connectStage` (registering, dialling, retrying, switching, or nil outside a connect), `.slowConnect` (the customer has waited on this connect — their bar open with the page not there yet, or a call they asked for not yet answered — past `GraineConfig.Timing.slowConnectMs`, 4 s by default) and `.callFailed` (the last start could not be connected on either transport; cleared by `start()`, an answered call, `end()` and `detach()`), for an app that draws its own bar.
- The brand's logo is drawn whole. Wherever it stands in for the launcher glyph — the launcher, the voice bar's avatar, the chat header's mark — it is fitted into the largest square its shape holds (70% of a circle, a squircle or a pill's height; 80% of a rounded or square shape), proportions kept, never cropped: the avatar drew it filling the circle, which cut a wordmark down to its middle and a square logo's corners off. It sits on its plate, `appearance.logoPlate` (`contract/DESIGN.md`, "The brand's logo"): the accent, or white with a hairline in the design's border colour (a pill's label then in near-black), so a logo in the brand's own colour no longer vanishes on the brand's own accent. Absent, it is the accent, as before. A logo that will not load gives way to the first letter on the accent.
- `GraineNativeAppearance.logoPlate` — `GraineLogoPlate.accent` or `.white` — for an app that draws its own launcher.
- Six new designs in the dashboard — Swiss Grid, Precision, Japandi Calm, Fintech Clear, Bauhaus and Gamified — reach this SDK as tokens, as every design does, with no release; the contract tests read every case in `contract/design.json`, those six included.

## 0.4.0

- Window chrome: the chat, caption and components open as desktop windows when the design says so — Desktop Buddy does. With the design's `chrome` set to `window` (`contract/DESIGN.md`, "Window chrome"), the caption card above the bar and every component card carry a title bar across the top: `surfaceRaised`, outlined below, in the card's own top corners, with the three traffic lights at the left and a centred title in SF Mono, lower case, in `textMuted` — "captions" on the caption; on a component card its own title, which moves up into the bar and is not drawn again below (the rows keep theirs), over a body on `surface` rather than `surfaceRaised`, so the bar reads as a title bar — Desktop Buddy's white window under a grey bar. The chat window (drawn complete, though this package carries calls only and does not show it yet) takes a title bar in place of its header: the heading after the online dot, the collapse chevron at its right end. The "coming" loader and the answered row are unchanged. Every other design draws exactly as before, and so does a session from a server that sends no `chrome`.
- `GraineThemeTokens.chrome` — `GraineDesignChrome.none` or `.window` — for an app that draws its own UI.

## 0.3.0

- The voice bar is the Garage's design, element by element. With a design, `GraineAgentBar` draws exactly what the dashboard's phone preview shows (`contract/DESIGN.md`, "Voice bar"): a 60-point bar on `surface` — frosted with glass — outlined, at `radius.xl`, with the floating shadow or the solid hard offset; the accent avatar with the launcher glyph (else the logo, else the first letter); the name and a status line whose four-bar meter moves at the design's pace (still under Reduce Motion or a design with no motion); a microphone that starts the call and then mutes it; and an end button that hangs up, or closes when there is no call. The line being said rides above it on a caption card, "YOU" over the customer's own lines, and rises into place with the design's easing. The status words are the contract's, in sentence case — including "Thinking…" with the dashboard's loader while the agent works out its answer. Without a design, the bar looks exactly as before.
- Icons in the design's style. The bar's icons are the SDK's own set — microphone, muted, hang up, send, chat, call, chevron, close — drawn from the same path data the dashboard draws, as outline, sharp, filled or duotone at the design's stroke. No emoji or symbol-font stand-ins.
- The design's typeface, loaded by the SDK. The SDK fetches the faces the design draws with from Graine (`/api/embed/font`), keeps them on disk, registers them and redraws the bar, the caption, the launcher and the components in them; until a face arrives, or if it never does, the system font at the same weight, silently. The app names no font. A family the app ships itself (`GraineConfig.fonts`, or bundled under its own name) wins and is never downloaded.
- `GraineVoice.phase` — idle, connecting, reconnecting, thinking, speaking or listening — for an app that draws its own bar.
- `GraineAgentBar(onClose:)`: called after a hang-up, or a close with no call, once the goodbye has left the speaker.
- Transitions use the Garage's curves for the standard and emphasized easings.

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
