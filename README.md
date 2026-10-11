# GraineInApp for iOS

The Graine in-app agent for native iOS (Swift, iOS 15+, no dependencies). The
agent sees the screen you describe, acts through actions you register, draws
components, and talks by voice. The call runs in a page Graine hosts, inside a
1×1 invisible `WKWebView` this SDK owns, so every audio fix (TURN relay, media
watchdog, WebSocket fallback) reaches your app without a release. Phone-style
calls on CallKit and VoIP pushes run natively instead — see
[Calls](#calls-callkit--voip-push).

## Install

In Xcode: **File → Add Package Dependencies…**, enter
`https://github.com/GraineAI/inapp-ios`, and add the `GraineInApp` library to
your app target. In a `Package.swift`:

```swift
.package(url: "https://github.com/GraineAI/inapp-ios", from: "0.6.1")
```

Integration guide: https://www.graine.ai/docs/in-app/ios

Add to `Info.plist`, because your app is the one asking for the microphone:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Used to talk to the in-app assistant.</string>
```

In the dashboard, add `app://` to the agent's **Allowed domains** (Embed &
Widgets). Without it, every session is refused with a 403.

**App Store privacy.** The SDK ships a privacy manifest that declares the
required-reason APIs it calls — system uptime, for timing, and `UserDefaults`,
for its call settings — and no tracking; Xcode adds it to your app's privacy
report. What your app collects through the agent (the customer's voice, and
what you report to it) is yours to declare in your App Store privacy details.

## Set up once, at launch

```swift
import GraineInApp

@main
struct MyApp: App {
    init() {
        GraineInApp.configure(GraineConfig(
            baseUrl: "https://www.graine.ai",
            publishableKey: "pk_live_…",
            appVersion: "2.4.0",
            debug: false            // true in debug builds: bridge traffic + page console in the log
        ))
    }
    var body: some Scene { WindowGroup { RootView() } }
}
```

## Tell it who and where

```swift
let graine = GraineInApp.shared
graine.identify(["name": user.firstName, "plan": user.plan])     // nil on sign-out
graine.setVariables(["cart_total": 1299])                          // nil under a key removes it
graine.setScreen(GraineScreen(
    screen: "kyc_documents",
    title: "Upload your documents",
    journey: .init(name: "KYC", step: 2, of: 4),
    fields: [GraineField(name: "pan", label: "PAN", value: pan, status: .invalid, error: "Not recognised")]
))
graine.track("otp_retry")                                          // context, never a nudge
```

Values are masked on the device (PAN, email, card, phone, Aadhaar) before they
leave it; report real values. `GraineMasking.addRule(pattern:token:)` adds your own.

## Let the agent act

```swift
let unregister = graine.registerAction("set_tenure") { args in
    tenure = args["months"] as? Int ?? 12
    return .ok("Tenure set to \(tenure) months")
}
graine.registerAction("upload_document", deferred: { args, done in
    upload(args) { ok in done(ok ? .ok("Uploaded") : .error("Upload failed")) }
})
print(graine.checkActions())   // usable / undeclared / unhandled
```

Handlers run on the main thread and must answer within six seconds. Declare
each action on the agent in the dashboard as well.

## The call, and the default UI

```swift
RootView()
    .overlay(GraineAgentBar(
        initialOffset: savedOffset,
        onPlacementChange: { savedOffset = $0 }      // persist where the customer dragged it
    ))
    .overlay(alignment: .bottom) {
        GraineWidgetView().padding(.horizontal, 12).padding(.bottom, 96)
    }
```

`GraineAgentBar` mounts the engine in the key window when it first appears
(`autoAttach`), names the network ("Weak connection", "No connection",
"Reconnecting…"), shows the dashboard's loader while connecting and while the
agent thinks, can be dragged, and rises above the keyboard. A connect says
where it is: a retry is the loader's "reconnecting" moment, a long one says
"Still connecting…" (never over words the brand chose), and one nothing could
carry says "Couldn’t connect · tap to retry". Its microphone
starts the call and then mutes it; its end button hangs up — or, with no call,
closes: pass `onClose:` to take the bar away when your app shows it on demand.
Anything in `.accessory { … }` rides with it.

Without the bar: `graine.voice.attach(to: window)` once, then
`graine.voice.start()` / `.end()` / `.setMuted(_:)`. `GraineVoice` is an
`ObservableObject`, so your own SwiftUI can draw from `connected`, `connecting`,
`phase` (idle, connecting, reconnecting, thinking, speaking, listening),
`quality`, `online`, `reconnecting`, `connectivity`, `captions`, and a connect's
own progress: `connectStage` (registering, dialling, retrying, switching),
`slowConnect` (waited on past `GraineConfig.Timing.slowConnectMs`, 4 s by
default) and `callFailed` (neither transport could carry it; `start()` tries
again).
`GraineListener` (held weakly) reports the same events, plus components
(`onWidget`), friction (`onFriction`) and errors.

Friction: when the customer sits on a screen with a field outstanding during a
call (45s by default, from the dashboard, overridable with
`GraineConfig.friction` / `configureFriction`), the agent is told
`stalled_on_step`. Call `noteInteraction()` when the customer does something
that is not a field edit.

## Calls (CallKit + VoIP push)

A WhatsApp-style call with your agent — the customer calling it, or your agent
ringing the customer — on the system's own call screen: the lock screen,
Bluetooth, the call going on with the screen off. `GraineInApp.shared.calls`
runs the call's audio in your app's own process (the platform's echo canceller,
no web view), over the same conversation as the in-app agent, so the agent
still sees the screen you describe and runs your actions.

**In Xcode**: Signing & Capabilities → **Push Notifications**, and **Background
Modes** → *Audio, AirPlay, and Picture in Picture* and *Voice over IP*. That
is, in `Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array><string>audio</string><string>voip</string></array>
<key>NSMicrophoneUsageDescription</key>
<string>Used to talk to the assistant.</string>
```

**At launch, every launch** (iOS wakes a terminated app for a VoIP push and
delivers it once this has run):

```swift
let calls = GraineInApp.configure(GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_live_…")).calls
calls.configure(GraineCallsConfig(
    displayName: "Acme Assistant",      // what the call shows; a push's caller_name wins
    ringtoneSound: nil,                 // a sound file in your bundle, or the system ringtone
    includesCallsInRecents: false,
    ringTimeout: 30                     // seconds before an unanswered ring is missed
))
calls.enableVoIPPushes { token in       // hex; nil when invalidated
    myServer.saveVoipToken(token)
}
calls.addListener(self)
```

**The customer calls the agent**: `calls.startCall(reason: "card_blocked", variables: ["order": "A-1043"])`
returns the call's id (nil while another call is live). The agent hears
`who_called = "customer"` and `call_reason`.

**The agent rings the customer**: your server sends a VoIP push (APNs headers
`apns-push-type: voip`, `apns-topic: <your bundle id>.voip`) with string keys:

```json
{ "type": "agent_call", "call_id": "c_123", "reason": "payment_due",
  "caller_name": "Acme", "variables": "{\"name\":\"Asha\"}" }
```

`type` and `call_id` are required. It rings through CallKit; answering opens
the conversation with `who_called = "agent"`, `call_reason` and the
variables. Every push is reported to CallKit before its completion runs, as
iOS requires — a malformed one, or one that arrives while a call is live, is
reported and ended at once. An app with its own `PKPushRegistry` passes the
payload to `calls.reportIncomingCall(payload:completion:)` instead.

**Tell your server what happened** (`GraineCallsListener`, held weakly, every
method optional):

```swift
func onCallOutcome(_ outcome: GraineCallOutcome, callId: String) {
    // .answered · .declined · .missed (ring timeout, or busy) ·
    // .ended(.local | .remote | .failed) · .failed(reason) — it never connected
}
func onIncomingCall(_ call: GraineIncomingCall) {}
func onCallState(_ state: GraineCallState, callId: String?) {}
```

In the call: `calls.end()`, `setMuted(_:)`, `setSpeaker(_:)` (earpiece by
default) and `answer()`. `GraineCalls` is an `ObservableObject` — `state`,
`callId`, `callerName`, `muted`, `speakerOn`, `agentSpeaking`, `caption`,
`connectedAt` — and `GraineCallView()` is a ready call screen for while your
app is open. One call at a time: starting one ends any call `voice` holds, and
`voice.start()` refuses while one is live. `endOnBackground` is `voice`'s
setting; a native call keeps going in the background, as a phone call does.

**Frameworks**: the React Native (`@graineai/inapp-react-native-calls`) and
Flutter (`graine_inapp`) packages carry these same calls and drive them
through `GraineCallsHost`. In those apps, use the package's own API; the
host is not called directly.

## The brand's design

The look is chosen in the dashboard (Web components → Design) and arrives with
the session, already resolved into light and dark tokens. The bar, the
components, the loader and `GraineLauncher` draw them — nothing to configure:

```swift
RootView()
    .overlay(alignment: .bottomTrailing) { GraineLauncher().padding(20) }
```

`GraineAgentBar` is the voice bar the dashboard's Garage previews, element by
element: the design's colours, corners, outline, shadow or hard offset, glass,
icon style (the SDK's own icons, drawn from their paths) and motion — the
status meter moves at the design's pace, and arrivals rise with its easing.
A design with window chrome (Desktop Buddy's) opens the caption and every
component as a desktop window: a title bar with traffic lights and a
monospaced title.
The design's typeface is loaded by the SDK itself: it fetches the faces the
design uses from Graine, keeps them on disk, registers them and redraws, and
until they arrive (or if they never do) draws the system font at the same
weight. Your app names no font. A family your app ships itself wins and is
never downloaded — map it to your font's registered name with
`GraineConfig(…, fonts: ["Inter": "InterVariable"])` if the two differ.

The brand's logo, wherever it stands in for the launcher glyph (the launcher,
the bar's avatar), is drawn whole — fitted into the largest square its shape
holds, never cropped — on the plate the dashboard chose for it
(`GraineNativeAppearance.logoPlate`): the accent, or white with a hairline.

The launcher places the call on a tap and ends it on the next; pass `action:`
to open your own UI instead. `"auto"` follows the device's light or dark, and switches with it. An app that
draws its own UI reads the same tokens from `graine.theme` (or `onTheme`).

## Tests

Pure logic lives in `Sources/GraineInApp/Core` (Foundation only) and is tested
on a Mac against `contract/fixtures.json`, `contract/rn-parity.json`,
`contract/design.json` and `contract/native-calls.json` —
answers generated by the React Native SDK itself, which every Graine SDK must
reproduce. With Xcode, `swift test`.
With only the Command Line Tools, SwiftPM does not put swift-testing on the
runner's framework path, so pass it:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

A whole call can also be run against your agent from a Mac, end to end, with a
spoken WAV standing in for the microphone. Opt-in, and the key only from the
environment:

```sh
GRAINE_LIVE_E2E=1 GRAINE_E2E_KEY=<publishable key> swift test --filter NativeCallLiveTests
```

(`GRAINE_E2E_WAV` names a 16 kHz mono PCM16 WAV; without it the test makes one with `say`.)
