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
.package(url: "https://github.com/GraineAI/inapp-ios", from: "0.8.0")
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

## Several agents in one app

Configure each agent under a name, with its own publishable key, and hand the
one a screen talks to to its views:

```swift
GraineInApp.configure(GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_live_support…"))       // the default
GraineInApp.configure(GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_live_sales…"), name: "sales")

GraineChatView(graine: GraineInApp.named("sales"))      // on Plans
GraineAgentBar()                                        // elsewhere: the default agent
GraineInApp.shared.calls.startCall(reason: "upgrade", agent: "sales")
```

Each agent has its own design, chat, voice bar, actions, and scheduling and
memory requests. The customer, the device and the screen are the app's:
`identify` on any agent identifies them for every agent (`identify(nil)` signs
out everywhere), and `setScreen`, `track` and taps reach every agent. One
conversation at a time across agents. A ring Graine sends rings with the
agent it is from.

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

A form that changes one field at a time can say just that:
`graine.updateField(GraineField(name: "pan", value: pan, status: .invalid))`,
`graine.removeField("otp")`, and `graine.clearScreen("kyc_documents")` in a
screen's teardown (it clears only if that screen is still the one described).
Taps on controls with an accessibility identifier (or a button's label) reach
the agent as `tap:<name>` — never a value — at most two a second
(`GraineConfig.captureTaps`, on by default); name a SwiftUI control with
`.graineTap("pay")`, or call `graine.tap("pay")`.

## Who the customer is, and memory

```swift
graine.identify(["user_id": user.id, "name": user.firstName])            // memory on by default
graine.identify(["user_id": user.id], memory: false)                     // this customer: not remembered
graine.setMemory(true)                                                   // change their mind later
let kept = try await graine.memories()                                   // what the agent remembers about them
let deleted = try await graine.forgetMemory()                            // delete what the agent remembers about them
graine.identify(nil)                                                     // sign-out
```

The agent's **Who is the user?** setting (Agent → Memory, in the dashboard) names
the trait that says who the customer is — `user_id` unless you chose `email`,
`phone` or a custom trait. Its value is sent only when a conversation starts,
never in the prompt's variables or the screen context; Graine keeps a one-way
key of it, not the value. A placeholder (`"guest"`, `"null"`, a masked value)
is nobody: that conversation is anonymous and has no memory. The memory
choice is remembered for each customer on the device. `graine.installId` is
this install's id, kept in the Keychain through reinstalls.

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
call or a chat (45s by default, from the dashboard, overridable with
`GraineConfig.friction` / `configureFriction`), the agent is told
`stalled_on_step`. Call `noteInteraction()` when the customer does something
that is not a field edit.

The bar draws the agent's components itself, above the bar — unless your app
mounts its own `GraineWidgetView`, which then draws them alone.
`graine.reopenComponent()` puts back the last one the customer closed.

## The chat

The bar offers what the dashboard offers (Embed & Widgets → What visitors
get): the call, the chat, or both with a switch between them —
`GraineAgentBar(surface: .chat)` opens on the chat when both are allowed. As a
screen of its own:

```swift
NavigationLink("Ask our assistant") { GraineChatView() }          // SwiftUI
present(GraineChatViewController(), animated: true)                // UIKit
```

Or draw your own from `graine.chat` (`GraineChat`, an `ObservableObject`):
`open()` when the customer is in the chat, `send(_:)`, `close()` when they
leave, and `turns` (one per message, each reply its own), `status` and
`typing`. A message typed while offline is shown at once and sent when the
chat is back; a dropped connection is made again on its own, then waits for
the customer (or `retry()`). One conversation at a time: the chat ends a call
and a call closes the chat. `GraineListener.onChatMessage(_:)` hears each
reply (`proactive` when the agent spoke up unasked). Where Graine rings your
customers, the chat window shows their booked calls on an **Upcoming calls**
card, with Cancel (`chat.upcomingCalls`, `cancelUpcomingCall(id:)`).

### Conversations continue

A customer you `identify(_:)` who comes back — later today, tomorrow, on their
other phone — finds the chat where they left it, and the agent picks up from
there instead of greeting them again. The chat opens with the recent messages
(the last 50, kept for a while after the last one), earlier calls show as one
"Voice call · 6:05 PM" row, and day lines say Today, Yesterday or the date.
Drawing your own chat? `turn.restored` marks a message from an earlier
conversation and `turn.channel` (`.chat`, `.voice`) where it was said.
`try await chat.newConversation()` starts a fresh thread (the header of
`GraineChatView` offers it while an earlier conversation is on screen); what
the agent remembers about the customer stays. `forgetMemory()` clears the chat
on screen too. Anonymous customers, and those with memory off, start fresh
every time; each agent in your app keeps its own conversation.

## A bigger chat window

How big the bar's chat opens is set per agent in the dashboard — **Embed &
Widgets → Appearance → Chat window → Window size** — and the bar draws it with
no code:

| Size | On an iPhone | On an iPad |
|---|---|---|
| Compact | The window above the bar, as always | The same |
| Large | A sheet over most of the screen, the app dimmed behind it; drag it down or tap outside to close | A panel 420 wide in the bottom corner |
| Full screen | The whole screen, closed with the chevron at the top left | The whole screen |

Your app can choose otherwise, for every chat or for one:

```swift
GraineInApp.configure(GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: "pk_live_…", chatSize: .large))

GraineInApp.shared.chat.open(size: .full)   // opens the chat now, at this size, this once
```

The size passed to `open(size:)` wins until the chat closes, then
`GraineConfig.chatSize`, then the dashboard's. A mounted `GraineAgentBar` moves
to the chat when you open it this way, and switching between the call and the
chat keeps the size. `GraineChatView` and `GraineChatViewController` stay as
they are, for a chat you place yourself.

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

**When Graine rings your customers** (your workspace uploaded its push
credentials under In-app calling, in the dashboard), that is all: call
`calls.enableVoIPPushes()` at launch — no `onToken` needed — and the SDK
registers the token with Graine, rings the calls Graine sends, and tells
Graine what became of each. Customers can book a call when the agent allows it:

```swift
let rules = graine.schedulingRules                 // usersCanBook, earliest(now:), latest(now:), …
let call = try await graine.scheduleCall(at: tomorrowAt6pm, reason: "Finish my KYC")   // status .scheduled
let upcoming = try await graine.scheduledCalls()  // [GraineScheduledCall], upcoming first
let status = try await graine.cancelScheduledCall(id: call.id)                          // .cancelled
```

`scheduleCall` checks the rules before it sends anything. A refusal is a
`GraineServiceError` with a typed `code`: `.schedulingOff`, `.tooSoon`,
`.tooFar`, then the server's `.outsideWindow` (the agent's calling hours, in
the phone's time zone), `.tooManyPending`, `.rateLimited` (with
`retryAfterSeconds`).

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
the conversation with `who_called = "agent"` (`"scheduled"` for a call Graine
rang at a booked time), `call_reason` and the variables. Every push is reported to CallKit before its completion runs, as
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
`transcript`, `connectedAt`, `hosted` — and `GraineCallView()` is a ready call
screen for while your app is open, drawn in the brand's design (Web components →
Design → Call screen): every state — ringing ("Scheduled call" for a call
Graine rang for a booking), connecting, the call, ended, and a missed ring,
which stays as "Missed call" with Call back (`calls.callBack()`) and Close
(`calls.dismissMissedCall()`):

```swift
.fullScreenCover(isPresented: .constant(calls.showsCallScreen)) { GraineCallView() }
```

The system's own call screen shows the call's name and, unless you set
`iconTemplateImageData`, the brand's launcher glyph. One call at a time: starting one ends any call `voice` holds, and
`voice.start()` refuses while one is live. `endOnBackground` is `voice`'s
setting; a native call keeps going in the background, as a phone call does.

**Frameworks**: the React Native (`@graineai/inapp-react-native-calls`) and
Flutter (`graine_inapp`) packages carry these same calls and drive them
through `GraineCallsHost`. In those apps, use the package's own API; the
host is not called directly.

## Booking a call from your app

When your workspace has Graine ring its customers and the agent lets them book
(Calls & scheduling, in the dashboard), the SDK draws the booking screen itself
— "Call me at…" with no screen of your own:

```swift
if graine.bookingAvailable {                    // rung here, booking on, the customer identified
    if let call = await graine.presentBooking(reason: "Card replacement") {
        print("Booked:", call.id, call.at as Any)   // nil: closed without booking
    }
}
```

The sheet is drawn in the agent's design, light or dark: the day (chips from
today to the furthest day the agent allows), the time on the system's time
wheel (every 5 minutes, and only times the agent's rules allow), the phone's
time zone, "What's it about? (optional)" — 120 characters, kept with the call
for the agent, never in the push; `reason` fills it — and **Book call**. A
refusal stays in the sheet as one line: "Pick a time at least 5 minutes from
now", "Pick a time within 14 days", "That time is outside the hours we can call
— pick another", "You already have 3 calls booked — cancel one first", "Sign
in to book a call", "Couldn't book just now — try again". Once it is booked,
the sheet says when the agent will call, and Done closes it. A sheet on an
iPhone, a centred panel on an iPad.

- **SwiftUI**: `.graineBookingSheet(isPresented: $booking) { call in … }`, or
  `GraineBookingView { call in … }` wherever you present it yourself.
- **UIKit**: `present(GraineBookingViewController { call in … }, animated: true)`.
- **Objective-C**: `[graine presentBookingWithReason:nil completion:^(GraineObjCScheduledCall *call) { … }];`

`bookingAvailable` is each agent's own: true only when Graine rings this iPhone
(the workspace's In-app calling, for iOS), the agent lets customers book, and
the customer is identified with the trait the agent's Identity setting names
(otherwise a booking is refused with `identityRequired`). The SDK's chat window
follows the same rule: **Book a call** under the booked calls in its Upcoming
calls card, or on its own in the card's place when none are booked — and none
when the design hides the booked-calls card. To list or cancel calls in your
own screens, `scheduledCalls()` and `cancelScheduledCall(id:)`.

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
