## 0.6.1

- **Answering a call checks the microphone**, as placing one does. CallKit's answer is never held up: once it is fulfilled, a granted microphone connects the call, a refused one ends it `failed` ("The microphone permission was not granted.") after `answered`, and one never asked for is asked for while the call stays connecting — refused, or no answer within 60 seconds, ends it the same way.
- `GraineCallsHost` takes a `debug` option, so React Native and Flutter apps can turn on the SDK's debug log for calls.

## 0.6.0

- **Calls like WhatsApp**, through CallKit and VoIP pushes: `GraineInApp.shared.calls` (`GraineCalls`). The customer calls your agent with `startCall(reason:variables:)`, which returns the call's id, or your agent rings the customer through a VoIP push — `enableVoIPPushes(onToken:)`, or `reportIncomingCall(payload:completion:)` for an app with its own `PKPushRegistry`. Calls use the system's call screen, answer from the lock screen, work over Bluetooth and keep going with the screen off. One call at a time.
- **Every VoIP push rings**, as iOS requires. A push that arrives during a live call is shown and ended at once, and your app hears it as `missed`; one that is not an agent call is ended at once too, and heard as `failed` if it carries a `call_id`. The push your server sends: `type: "agent_call"`, `call_id` (required), `reason`, `caller_name` and `variables` (a JSON object, as a string).
- **The call's audio runs in your app**, with the platform's echo cancellation: the earpiece by default, Bluetooth headsets, `setSpeaker(_:)` and `setMuted(_:)`. Audio starts when CallKit hands it over, and the agent's greeting waits for it. Interruptions and route changes are handled.
- **The same agent and context as the assistant bar**: who the customer is (`identify`, `setVariables`), the current screen, and your registered actions. Each call also sets `who_called` (`"customer"` for `startCall`, `"agent"` for a ring) and `call_reason`; the push's `variables` win over the rest.
- **Outcomes for your server**: `GraineCallsListener` reports every call's outcome with its id — `answered`, `declined`, `missed` (no answer within `ringTimeout`, 30 s by default), `ended(.local | .remote | .failed)` and `failed(reason)` — plus incoming calls and state changes.
- **Your call screen, or the SDK's**: `GraineCalls` is an `ObservableObject` (`state`, `callId`, `callerName`, `muted`, `speakerOn`, `agentSpeaking`, `caption`, `connectedAt`); `GraineCallView` is a SwiftUI call screen with mute, speaker and end, and answer and decline while it rings.
- `GraineCallsConfig`: `displayName`, `ringtoneSound`, `iconTemplateImageData`, `includesCallsInRecents` (off by default) and `ringTimeout`. Your app adds `UIBackgroundModes` `audio` and `voip`, Push Notifications, and `NSMicrophoneUsageDescription`.
- `GraineCallsHost`, for the React Native and Flutter call packages: they drive these same calls through it, and it keeps their options so that a VoIP push that wakes your app rings before any JavaScript or Dart has run. A native app uses `GraineInApp.shared.calls` and never needs it.
- Starting a call ends a conversation in the assistant bar, and the bar cannot start one while a call is live. The assistant bar is otherwise unchanged.
- `GraineSessionConfig.wsHost`, filled in by the server.
- A privacy manifest (`PrivacyInfo.xcprivacy`): the required-reason APIs the SDK calls — system uptime and `UserDefaults` — and no tracking.

Guide: [In-app calling](https://www.graine.ai/docs/in-app/calling).

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

- Back in the foreground, an idle engine is told to get ready again (`graine:warm`). The engine keeps its line ready so a tap costs only the call itself, but a phone drops that idle connection while the app is in the background. The SDK now tells the engine when the app returns — only when the page is ready, never during a call.
- Connecting is faster in the hosted engine itself — a warm tap connects in about 0.2 s — with no change to this package.

## 0.1.0

First release.

- `GraineInApp` and `GraineVoice` host Graine's voice engine in a Swift package.
- Screen context, prompt variables and in-app actions, masked on the device before anything leaves it.
- Components the agent draws, the loader, the draggable keyboard-aware bar, friction detection and connection quality.
- Tested against the same contract as the React Native, Android and Flutter SDKs.
