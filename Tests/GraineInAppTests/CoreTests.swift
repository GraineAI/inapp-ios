import Foundation
import Testing
@testable import GraineInApp

/*
 * The pure logic, proven without a device. Most cases are ports of the Android
 * SDK's CoreTest.kt and the React Native SDK's node tests, with the same
 * expected values; the masking edge cases were produced by running the React
 * Native SDK's own maskString.
 */

@Suite struct ProtocolTests {
    private func parse(_ raw: String?) -> PageMessage? { GraineProtocol.parse(raw) }

    @Test func aMessageIntoThePageIsAPostMessageThatEvaluatesToTrue() throws {
        let js = try #require(GraineProtocol.deliver(GraineProtocol.out(GraineProtocol.Out.setMuted, ["muted": true])))
        #expect(js.hasPrefix("window.postMessage({"))
        #expect(js.contains("\"type\":\"graine:set-muted\""))
        #expect(js.contains("\"muted\":true"))
        #expect(js.hasSuffix("\"*\"); true;"))
    }

    @Test func aLineSeparatorNeverReachesThePageRaw() throws {
        let js = try #require(GraineProtocol.deliver(GraineProtocol.out("graine:test", ["text": "a\u{2028}b\u{2029}c"])))
        #expect(!js.contains("\u{2028}"))
        #expect(!js.contains("\u{2029}"))
    }

    @Test func everyMessageThePageSendsIsUnderstood() throws {
        guard case .ready? = parse(#"{"type":"graine:ready"}"#) else { Issue.record("ready"); return }

        guard case let .call(connected, connecting)? = parse(#"{"type":"graine:call","connected":true,"connecting":false}"#) else {
            Issue.record("call"); return
        }
        #expect(connected)
        #expect(!connecting)

        guard case let .muted(muted)? = parse(#"{"type":"graine:muted","muted":true}"#) else { Issue.record("muted"); return }
        #expect(muted)

        guard case let .caption(role, text, live)? = parse(#"{"type":"graine:caption","role":"agent","text":"Hi Asha","live":true}"#) else {
            Issue.record("caption"); return
        }
        #expect(role == .agent)
        #expect(text == "Hi Asha")
        #expect(live)

        guard case .ended? = parse(#"{"type":"graine:ended"}"#) else { Issue.record("ended"); return }

        guard case let .micDenied(reason)? = parse(#"{"type":"graine:mic-denied","reason":"NotFoundError"}"#) else {
            Issue.record("mic-denied"); return
        }
        #expect(reason == "NotFoundError")
        guard case let .micDenied(unnamed)? = parse(#"{"type":"graine:mic-denied"}"#) else { Issue.record("mic-denied"); return }
        #expect(unnamed == "NotAllowedError")

        guard case let .network(online)? = parse(#"{"type":"graine:network","online":false}"#) else { Issue.record("network"); return }
        #expect(!online)

        guard case let .reconnecting(active)? = parse(#"{"type":"graine:reconnecting","active":true}"#) else {
            Issue.record("reconnecting"); return
        }
        #expect(active)

        guard case let .progress(stage)? = parse(#"{"type":"graine:progress","stage":"retrying"}"#) else {
            Issue.record("progress"); return
        }
        #expect(stage == .stage(.retrying))
        guard case let .progress(failed)? = parse(#"{"type":"graine:progress","stage":"failed"}"#) else {
            Issue.record("progress failed"); return
        }
        #expect(failed == .failed)

        guard case let .quality(rtt, jitter, loss)? = parse(#"{"type":"graine:quality","sample":{"rtt":480,"jitter":40,"loss":0.1}}"#) else {
            Issue.record("quality"); return
        }
        #expect(GraineConnectionQuality.classify(rttMs: rtt, jitterMs: jitter, loss: loss) == .poor)

        guard case let .transport(transport, requested, why, message)? =
            parse(#"{"type":"graine:transport","transport":"ws","requested":"rtc","reason":"not_configured","message":"no realm"}"#) else {
            Issue.record("transport"); return
        }
        #expect(transport == .websocket)
        #expect(requested == .webrtc)
        #expect(why == "not_configured")
        #expect(message == "no realm")

        guard case let .appAction(actionId, name, arguments)? =
            parse(#"{"type":"graine:app-action","action":{"action_id":"a1","name":"set_tenure","arguments":{"months":24}}}"#) else {
            Issue.record("app-action"); return
        }
        #expect(actionId == "a1")
        #expect(name == "set_tenure")
        #expect(arguments["months"] as? Int == 24)

        guard case let .widget(widget)? = parse(#"{"type":"graine:widget","widget":{"kind":"product_list","widget_id":"w1"}}"#) else {
            Issue.record("widget"); return
        }
        #expect(widget["widget_id"] as? String == "w1")

        guard case let .widgetPending(hint)? = parse(#"{"type":"graine:widget-pending","widget":{"kind":"product_list"}}"#) else {
            Issue.record("widget-pending"); return
        }
        #expect(hint["kind"] as? String == "product_list")
    }

    @Test func anythingThatIsNotOursIsIgnoredRatherThanGuessedAt() {
        let raws: [String?] = [
            nil, "", "not json", "{}", #"{"type":"graine:unheard-of"}"#, #"{"type":"graine:app-action"}"#, "[1,2]",
            #"{"type":"graine:progress","stage":"teleporting"}"#,
        ]
        for raw in raws {
            #expect(parse(raw) == nil, "raw: \(String(describing: raw))")
        }
    }

    @Test func aMissingQualityNumberIsUnknownNotZero() {
        // Zero would read as a perfect line. Absent is not perfect.
        guard case let .quality(rtt, jitter, loss)? = parse(#"{"type":"graine:quality","sample":{}}"#) else {
            Issue.record("quality"); return
        }
        #expect(GraineConnectionQuality.classify(rttMs: rtt, jitterMs: jitter, loss: loss) == .unknown)
        // A negative, a string or a boolean is not a measurement either.
        guard case let .quality(r2, j2, l2)? = parse(#"{"type":"graine:quality","sample":{"rtt":-1,"jitter":"40","loss":true}}"#) else {
            Issue.record("quality"); return
        }
        #expect(r2 == nil)
        #expect(j2 == nil)
        #expect(l2 == nil)
    }

    @Test func valuesAreEncodedAsEncodeURIComponentDoes() {
        // Expected value produced by node's encodeURIComponent.
        #expect(GraineProtocol.encode("a b/c?d&e=f#g!~*'()é✦") == "a%20b%2Fc%3Fd%26e%3Df%23g!~*'()%C3%A9%E2%9C%A6")
        #expect(GraineProtocol.encode("agent 1") == "agent%201")
    }

    @Test func theAccentIsTheHexWithoutItsHashAndABlankOneIsLeftOut() {
        let base = { (accent: String?) in
            GraineProtocol.engineUrl(baseUrl: "https://www.graine.ai//", voiceAgentId: "a", transport: .websocket,
                                     cacheKey: "k", idle: false, publishableKey: "pk", accent: accent)
        }
        #expect(base("  #318ce7 ") == "https://www.graine.ai/embed/a?mode=voice&branding=0&embed=1&transport=ws&b=k&pk=pk&accent=318ce7")
        #expect(base("") == "https://www.graine.ai/embed/a?mode=voice&branding=0&embed=1&transport=ws&b=k&pk=pk")
        #expect(base("#") == "https://www.graine.ai/embed/a?mode=voice&branding=0&embed=1&transport=ws&b=k&pk=pk")
    }

    @Test func debugLogsNameTheMessageWithoutTheCustomersValues() {
        let vars = GraineProtocol.out(GraineProtocol.Out.variables, ["variables": ["name": "Asha", "phone": "9876543210"]])
        #expect(GraineProtocol.redactForLog(vars) == "{name, phone}")
        let fields: [[String: Any]] = [["value": "secret"]]
        let inner: [String: Any] = ["screen": "kyc", "fields": fields]
        let context: [String: Any] = ["type": GraineProtocol.Out.appContext, "context": inner]
        #expect(GraineProtocol.redactForLog(context) == "screen=kyc")
    }

    @Test func theBridgeIsInstalledUnderTheNameThePageLooksFor() {
        #expect(
            EngineScripts.bridge
                == "window.ReactNativeWebView = { postMessage: function(s){ window.webkit.messageHandlers.graine.postMessage(String(s)); } };"
        )
        #expect(EngineScripts.socketTrace.contains("String(url).split('?')[0]"))
        #expect(EngineScripts.socketTrace.hasSuffix("})(); true;"))
    }
}

@Suite struct MaskingTests {
    /// Where ICU's Unicode-aware `\b` / `\d` / `\s` would have diverged from JavaScript. Expected values from the RN SDK.
    @Test func nonAsciiInputIsMaskedExactlyAsJavaScriptMasksIt() {
        let cases: [(String, String)] = [
            ("पैनABCDE1234F", "पैन[PAN]"),
            ("ÉABCDE1234F", "É[PAN]"),
            ("ABCDE1234Fé", "[PAN]é"),
            ("ABCDE1234F_x", "ABCDE1234F_x"),
            ("०9876543210", "०[PHONE]"),
            ("९८७६५४३२१०", "९८७६५४३२१०"),
            ("1234\u{0B}5678\u{0B}9012", "[AADHAAR]"),
            ("1234\u{A0}5678\u{A0}9012", "[AADHAAR]"),
            ("+91\u{2009}9876543210", "[PHONE]"),
            ("call +91-9876543210", "call [PHONE]"),
            ("a.b@c.io and x_y@z-w.com", "[EMAIL] and [EMAIL]"),
            ("4111-1111-1111-1111", "[CARD]"),
            ("id 12345678901234567890123", "id 12345678901234567890123"),
            ("नाम आशा, फ़ोन ९८७६५४३२१०", "नाम आशा, फ़ोन ९८७६५४३२१०"),
        ]
        for (input, expected) in cases {
            #expect(GraineMasking.mask(input) == expected, "input: \(input)")
        }
    }

    @Test func aCustomRuleCoversEveryMatchAndABadPatternIsRefused() {
        GraineMasking.clearCustomRules()
        defer { GraineMasking.clearCustomRules() }
        #expect(GraineMasking.addRule(pattern: "POL-[0-9]{6}", token: "[POLICY]"))
        #expect(GraineMasking.mask("POL-123456 and POL-654321") == "[POLICY] and [POLICY]")
        #expect(!GraineMasking.addRule(pattern: "("))
    }

    @Test func deepMaskingMasksValuesNotKeys() throws {
        let list: [Any] = ["call 9876543210", 42]
        let nested: [String: Any] = ["list": list]
        let input: [String: Any] = ["pan": "ABCDE1234F", "nested": nested, "ABCDE1234F": "key stays"]
        let out = try #require(GraineMasking.deep(input) as? [String: Any])
        #expect(out["pan"] as? String == "[PAN]")
        #expect(out["ABCDE1234F"] as? String == "key stays")
        let inner = try #require((out["nested"] as? [String: Any])?["list"] as? [Any])
        #expect(inner.first as? String == "call [PHONE]")
        #expect(inner.last as? Int == 42)
    }
}

@Suite struct VariableStoreTests {
    @Test func precedenceIsDashboardThenBuildThenRuntimeThenIdentity() {
        let v = VariableStore(buildTime: ["plan": "Free", "city": "Pune"])
        v.setDashboardDefaults(["plan": "Default", "greeting": "Hi"])
        v.setRuntime(["plan": "Plus", "cart_total": 1299])
        v.setIdentity(["name": "Asha", "plan": "Pro"])
        #expect(v.merged() == ["plan": "Pro", "greeting": "Hi", "city": "Pune", "cart_total": "1299", "name": "Asha"])
    }

    @Test func runtimeMergesRemovesOnNilAndDropsObjects() {
        let v = VariableStore()
        v.setRuntime(["a": "1", "nested": ["x": 1], "list": [1]])
        v.setRuntime(["b": true, "ratio": 0.5])
        v.setRuntime(["a": nil])
        #expect(v.merged() == ["b": "true", "ratio": "0.5"])
        v.setRuntime(nil)
        #expect(v.merged() == [:])
    }

    @Test func whatTheAppHandsOverIsMaskedLikeEverythingElse() {
        let v = VariableStore()
        v.setIdentity(["name": "Asha", "phone": "9876543210"])
        v.setRuntime(["note": "PAN ABCDE1234F"])
        #expect(v.merged()["phone"] == "[PHONE]")
        #expect(v.merged()["note"] == "PAN [PAN]")
        #expect(v.merged()["name"] == "Asha")
    }

    @Test func signOutClearsWhoItWas() {
        let v = VariableStore()
        v.setIdentity(["name": "Asha"])
        v.setIdentity(nil)
        #expect(v.merged().isEmpty)
    }

    @Test func aWholeNumberHasNoDecimalPoint() {
        #expect(VariableStore.flattenOne(12.0) == "12")
        #expect(VariableStore.flattenOne(NSNumber(value: 1299)) == "1299")
        #expect(VariableStore.flattenOne(NSNumber(value: Int64(12_345_678_901_234_567))) == "12345678901234567")
        #expect(VariableStore.flattenOne(false) == "false")
        #expect(VariableStore.flattenOne(NSNull()) == nil)
    }
}

@Suite struct JSONTests {
    @Test func aBooleanIsNeverAOneAndAOneIsNeverABoolean() throws {
        #expect(JSON.bool(true) == true)
        #expect(JSON.bool(NSNumber(value: true)) == true)
        #expect(JSON.bool(NSNumber(value: 1)) == nil)
        #expect(JSON.bool(1) == nil)
        let parsed = try #require(JSON.object(from: #"{"x":true,"y":1}"#))
        let x = try #require(parsed["x"])
        let y = try #require(parsed["y"])
        #expect(JSON.bool(x) == true)
        #expect(JSON.bool(y) == nil)
        #expect(JSON.number(x) == nil)
        #expect(JSON.number(y)?.intValue == 1)
    }

    @Test func whatJSONSerializationCannotWriteBecomesNullNotACrash() {
        let input: [String: Any?] = ["a": nil, "b": true, "c": 1, "d": 2.5, "e": Double.nan]
        #expect(JSON.canonical(input) == #"{"a":null,"b":true,"c":1,"d":2.5,"e":null}"#)
    }
}

@Suite struct LoadWatchdogTests {
    @Test func aLoadStillArrivingIsNeverCalledStuckHoweverSlow() {
        let w = LoadWatchdog(stallMs: 40, bootMs: 40, hardCapMs: 10_000)
        w.start(now: 0)
        var t: Int64 = 0
        for p in 1...20 {
            t += 30
            w.progress(p * 4, now: t)
            #expect(w.check(now: t) == .wait)
        }
    }

    @Test func silenceIsAStallAndAMutePageIsABootTimeout() {
        let w = LoadWatchdog(stallMs: 40, bootMs: 40)
        w.start(now: 0)
        w.progress(30, now: 10)
        #expect(w.check(now: 60) == .stalled)
        w.start(now: 0)
        w.progress(100, now: 10)
        #expect(w.check(now: 60) == .bootTimeout)
    }

    @Test func aLowerProgressReportIsNotThePageGoingBackwards() {
        let w = LoadWatchdog(stallMs: 40)
        w.start(now: 0)
        w.progress(90, now: 10)
        w.progress(10, now: 30)
        w.progress(10, now: 45)
        #expect(w.check(now: 55) == .stalled)
    }

    @Test func aLinkThatDribblesForeverStillEnds() {
        let w = LoadWatchdog(stallMs: 1_000, hardCapMs: 100)
        w.start(now: 0)
        w.progress(50, now: 90)
        #expect(w.check(now: 101) == .loadCap)
    }

    @Test func itNeverWakesMoreThanFourTimesASecondAtTheDefaultWindow() {
        let w = LoadWatchdog()
        w.start(now: 0)
        #expect(w.nextCheckInMs(now: 14_999) == 250)
    }

    @Test func aShortWindowIsCheckedWithinAQuarterOfItself() {
        // A fixed 250ms floor gave a 40ms window six times the slop it asked for.
        let w = LoadWatchdog(stallMs: 40)
        w.start(now: 0)
        #expect(w.nextCheckInMs(now: 39) == 10)
    }

    @Test func theVerdictNamesTheReasonTheWayAndroidDoes() {
        #expect(LoadWatchdog.Verdict.stalled.rawValue == "stalled")
        #expect(LoadWatchdog.Verdict.bootTimeout.rawValue == "boot_timeout")
        #expect(LoadWatchdog.Verdict.loadCap.rawValue == "load_cap")
    }
}

@Suite struct RetryLadderTests {
    @Test func jitteredWithinAQuarterAndThenExhausted() {
        let lo = RetryLadder(delaysMs: [1_000, 2_000], random: { 0.0 })
        #expect(lo.next() == 750)
        #expect(lo.next() == 1_500)
        #expect(lo.next() == nil)
        #expect(lo.exhausted)
        let hi = RetryLadder(delaysMs: [1_000], random: { 1.0 })
        #expect(hi.next() == 1_250)
        hi.reset()
        #expect(!hi.exhausted)
    }
}

@Suite struct ContextFrameTests {
    @Test func theFrameIsTheShapeTheRuntimeReadsAndIsMasked() throws {
        let screen = GraineScreen(
            screen: "kyc_documents",
            title: "Upload your documents",
            journey: GraineScreen.Journey(name: "KYC", step: 2, of: 4),
            fields: [GraineField(name: "pan", label: "PAN", value: "ABCDE1234F", status: .invalid, error: "Not recognised")],
            availableActions: ["fill_pan"]
        )
        let frame = try #require(ContextFrame.build(
            screen: screen,
            screenSinceMs: 1_000,
            nowMs: 46_000,
            identity: ["name": "Asha"],
            appVersion: "2.4.0",
            recentEvents: [],
            registeredActions: ["fill_pan"]
        ))
        let ctx = try #require(frame["context"] as? [String: Any])
        #expect(ctx["screen"] as? String == "kyc_documents")
        #expect((ctx["journey"] as? [String: Any])?["step"] as? Int == 2)
        let field = try #require((ctx["fields"] as? [[String: Any]])?.first)
        #expect(field["value"] as? String == "[PAN]")
        #expect(field["status"] as? String == "invalid")
        #expect(field["optional"] == nil)
        #expect(ctx["idle_ms"] as? Int64 == 45_000)
        #expect((ctx["user"] as? [String: Any])?["name"] as? String == "Asha")
        #expect(ctx["app_version"] as? String == "2.4.0")
        #expect(frame["availableActions"] as? [String] == ["fill_pan"])
    }

    @Test func nothingToSayIsNoFrame() {
        #expect(ContextFrame.build(screen: nil, screenSinceMs: 0, nowMs: 0, identity: [:], appVersion: nil,
                                   recentEvents: [], registeredActions: []) == nil)
    }

    @Test func anEmptyListIsNeverSentByAccident() {
        // Absent means "everything the dashboard declared"; [] means "nothing here". Opposite instructions.
        #expect(ContextFrame.availableActions(stated: nil, registered: []) == nil)
        #expect(ContextFrame.availableActions(stated: nil, registered: ["a", "b"]) == ["a", "b"])
        #expect(ContextFrame.availableActions(stated: [], registered: ["a"]) == [])
        #expect(ContextFrame.availableActions(stated: ["a", "x"], registered: ["a"]) == ["a"])
        #expect(ContextFrame.availableActions(stated: ["x"], registered: ["a"]) == [])
    }

    @Test func anOptionalFieldSaysSo() throws {
        let screen = GraineScreen(screen: "s", fields: [GraineField(name: "middle_name", status: .empty, isOptional: true)])
        let frame = try #require(ContextFrame.build(screen: screen, screenSinceMs: 0, nowMs: 0, identity: [:],
                                                    appVersion: nil, recentEvents: [], registeredActions: []))
        let field = try #require(((frame["context"] as? [String: Any])?["fields"] as? [[String: Any]])?.first)
        #expect(field["optional"] as? Bool == true)
        #expect(field["status"] as? String == "empty")
    }

    @Test func aScreenIsUnchangedOnlyWhenEverythingIsTheSame() {
        let a = GraineScreen(screen: "s", data: ["amount": 1299])
        #expect(a == GraineScreen(screen: "s", data: ["amount": 1299]))
        #expect(a != GraineScreen(screen: "s", data: ["amount": 1300]))
        #expect(a != GraineScreen(screen: "s", title: "t", data: ["amount": 1299]))
    }
}

@Suite struct SessionTests {
    @Test func theSessionIsReadTheWayEveryPlatformReadsIt() {
        let actions: [Any] = [["tool_name": "fill_pan"], ["toolName": "open_screen"], ["name": "set_tenure"], ["other": "x"], "junk"]
        let friction: [String: Any] = ["idle": ["afterMs": 20_000]]
        let body: [String: Any] = [
            "agentId": "a1",
            "webcallAgentId": "",
            "appearance": ["audioTransport": "rtc", "accent": "318CE7"],
            "variables": ["plan": "Free"],
            "pageVersion": "dpl_1",
            "appActions": actions,
            "friction": friction,
        ]
        let s = GraineSessionConfig.parse(body)
        #expect(s.agentId == "a1")
        #expect(s.webcallAgentId == "a1")
        #expect(s.preferredTransport == .webrtc)
        #expect(s.accent == "318CE7")
        #expect(s.pageVersion == "dpl_1")
        #expect(s.declaredActions == ["fill_pan", "open_screen", "set_tenure"])
        #expect((s.friction?["idle"] as? [String: Any])?["afterMs"] as? Int == 20_000)
        #expect(GraineSessionConfig.parse([:]).preferredTransport == .websocket)
        #expect(GraineSessionConfig.parse([:]).friction == nil)
        #expect(GraineSessionConfig.parse(["pageVersion": NSNull()]).pageVersion == nil)
    }

    @Test func aRefusalIsASentenceForWhoeverHasToFixIt() throws {
        #expect(GraineSessionConfig.errorMessage(status: 200, body: nil) == nil)
        let forbidden = try #require(GraineSessionConfig.errorMessage(status: 403, body: ["error": "no_origin"]))
        #expect(forbidden.contains("\"app://\""))
        #expect(forbidden.contains("no_origin"))
        #expect(GraineSessionConfig.errorMessage(status: 401, body: nil)
            == "Publishable key was rejected. Check it against Embed & Widgets in the dashboard.")
        #expect(GraineSessionConfig.errorMessage(status: 500, body: nil) == "Embed rejected (500)")
        #expect(GraineSessionConfig.errorMessage(status: 429, body: ["error": "rate_limited"]) == "rate_limited")
    }
}

@Suite struct PlacementTests {
    private let b = PlacementMath.Bounds(windowHeight: 844, baseBottom: 96, barHeight: 64, topMargin: 48)

    @Test func draggingUpRaisesTheBarBecauseTheGesturesDyGrowsDownward() {
        #expect(PlacementMath.offsetDuringDrag(start: 0, dy: -120, b) == 120)
        #expect(PlacementMath.offsetDuringDrag(start: 100, dy: 30, b) == 70)
    }

    @Test func itCanNeverGoBelowItsAnchor() {
        #expect(PlacementMath.offsetDuringDrag(start: 0, dy: 500, b) == 0)
        #expect(PlacementMath.clampOffset(-40, b) == 0)
    }

    @Test func itCanNeverPassTheTopMargin() {
        let maxOffset = 844.0 - 48 - 64 - 96
        #expect(PlacementMath.clampOffset(10_000, b) == maxOffset)
        #expect(PlacementMath.offsetDuringDrag(start: maxOffset, dy: -1, b) == maxOffset)
    }

    @Test func beforeTheFirstLayoutADragCannotFlingItOffScreen() {
        var unmeasured = b
        unmeasured.barHeight = 0
        #expect(PlacementMath.clampOffset(10_000, unmeasured) < 844)
    }

    @Test func aSmallMovementIsATapInEitherAxis() {
        #expect(PlacementMath.isTap(dx: 3, dy: 4))
        #expect(!PlacementMath.isTap(dx: PlacementMath.dragSlop, dy: 0))
        #expect(!PlacementMath.isTap(dx: 0, dy: -PlacementMath.dragSlop))
    }

    @Test func garbageIsTheAnchorNotNaN() {
        #expect(PlacementMath.clampOffset(.nan, b) == 0)
        #expect(PlacementMath.clampOffset(.infinity, b) == 0)
    }

    @Test func theKeyboardLiftsTheBarOnlyAsFarAsItHasTo() {
        #expect(PlacementMath.bottomDistance(baseBottom: 16, offset: 0, keyboardLift: 0) == 16)
        #expect(PlacementMath.bottomDistance(baseBottom: 16, offset: 0, keyboardLift: 300) == 316)
        #expect(PlacementMath.bottomDistance(baseBottom: 16, offset: 200, keyboardLift: 300) == 316)
        // Parked above the keyboard already: it stays where the customer put it.
        #expect(PlacementMath.bottomDistance(baseBottom: 16, offset: 400, keyboardLift: 300) == 416)
    }
}

@Suite struct KeyboardTests {
    @Test func theBarRisesByWhatTheWindowDidNot() {
        #expect(KeyboardMath.liftFor(keyboardHeight: 336, windowShrink: 0) == 336)
        #expect(KeyboardMath.liftFor(keyboardHeight: 336, windowShrink: 336) == 0)
        #expect(KeyboardMath.liftFor(keyboardHeight: 336, windowShrink: 330) == 6)
        #expect(KeyboardMath.liftFor(keyboardHeight: 300, windowShrink: 0) == 300)
    }

    @Test func noKeyboardIsNoLiftWhateverTheWindowDid() {
        #expect(KeyboardMath.liftFor(keyboardHeight: 0, windowShrink: 0) == 0)
        #expect(KeyboardMath.liftFor(keyboardHeight: 0, windowShrink: 200) == 0)
        #expect(KeyboardMath.liftFor(keyboardHeight: .nan, windowShrink: 0) == 0)
        #expect(KeyboardMath.liftFor(keyboardHeight: -10, windowShrink: 0) == 0)
        #expect(KeyboardMath.liftFor(keyboardHeight: 200, windowShrink: -100) == 200)
    }

    @Test func theOverlapIsMeasuredSoTheBarIsNeverLiftedTwice() {
        // 390×844 area ending above the home indicator at 810; a 336pt keyboard from 508.
        #expect(KeyboardMath.overlap(areaMinX: 0, areaMaxX: 390, areaMaxY: 810,
                                     keyboardMinX: 0, keyboardMinY: 508, keyboardMaxX: 390, keyboardHeight: 336) == 302)
        // SwiftUI already moved the area above the keyboard.
        #expect(KeyboardMath.overlap(areaMinX: 0, areaMaxX: 390, areaMaxY: 500,
                                     keyboardMinX: 0, keyboardMinY: 508, keyboardMaxX: 390, keyboardHeight: 336) == 0)
        // A floating iPad keyboard off to one side.
        #expect(KeyboardMath.overlap(areaMinX: 0, areaMaxX: 300, areaMaxY: 810,
                                     keyboardMinX: 400, keyboardMinY: 500, keyboardMaxX: 700, keyboardHeight: 300) == 0)
    }
}

@Suite struct CallStateTests {
    @Test func aLiveTurnReplacesItselfAndAnEmptyLineIsAFullStop() {
        var lines: [GraineCaption] = []
        lines = CaptionLog.fold(lines, GraineCaption(role: .agent, text: "Hi", live: true))
        lines = CaptionLog.fold(lines, GraineCaption(role: .agent, text: "Hi Asha", live: true))
        #expect(lines == [GraineCaption(role: .agent, text: "Hi Asha", live: true)])
        #expect(CaptionLog.agentSpeaking(lines))
        lines = CaptionLog.fold(lines, GraineCaption(role: .agent, text: "", live: false))
        #expect(lines == [GraineCaption(role: .agent, text: "Hi Asha", live: false)])
        #expect(!CaptionLog.agentSpeaking(lines))
        lines = CaptionLog.fold(lines, GraineCaption(role: .customer, text: "", live: false))
        #expect(lines.count == 1, "nothing open to settle: ignored")
        lines = CaptionLog.fold(lines, GraineCaption(role: .customer, text: "Hello", live: false))
        #expect(lines.count == 2)
        for i in 0..<20 {
            lines = CaptionLog.fold(lines, GraineCaption(role: i % 2 == 0 ? .agent : .customer, text: "line \(i)", live: false))
        }
        #expect(lines.count == CaptionLog.history)
        #expect(lines.last?.text == "line 19")
    }

    private func status(_ change: (inout BarStatus.Input) -> Void) -> String {
        var s = BarStatus.Input(connectivity: .ready, online: true, reconnecting: false, connecting: false, ready: true,
                                muted: false, connected: false, quality: .unknown, agentSpeaking: false, micDenied: false)
        change(&s)
        return BarStatus.text(s)
    }

    @Test func theBarNamesTheNetwork() {
        #expect(status { _ in } == "tap to talk")
        #expect(status { $0.connected = true } == "listening")
        #expect(status { $0.connected = true; $0.agentSpeaking = true } == "speaking")
        #expect(status { $0.connected = true; $0.quality = .poor } == "weak connection")
        #expect(status { $0.connected = true; $0.muted = true } == "muted")
        #expect(status { $0.connecting = true } == "connecting…")
        #expect(status { $0.ready = false } == "connecting…")
        #expect(status { $0.connected = true; $0.reconnecting = true } == "reconnecting…")
        #expect(status { $0.connectivity = .retrying } == "reconnecting…")
        #expect(status { $0.connected = true; $0.online = false } == "no connection")
        #expect(status { $0.connectivity = .failed; $0.online = false } == "couldn't load · tap to retry")
        #expect(status { $0.micDenied = true } == "needs microphone")
    }
}

@Suite struct AppearanceTests {
    @Test func theAccentArrivesWithOrWithoutItsHash() {
        #expect(Appearance.accent("318CE7") == "#318CE7")
        #expect(Appearance.accent(" #abc ") == "#abc")
        #expect(Appearance.accent("red") == nil)
        #expect(Appearance.accent(nil) == nil)
    }

    @Test func whatReadsOnTheAccentIsChosenByLuminance() {
        #expect(Appearance.onAccent("#318CE7") == "#FFFFFF")
        #expect(Appearance.onAccent("#FFD60A") == "#101318")
    }

    @Test func anAbsentRadiusIsTheSchemasEighteenNotZero() {
        #expect(Appearance.radius(nil) == 18)
        #expect(Appearance.radius(["radius": "12"]) == 12)
        #expect(Appearance.radius(["radius": ""]) == 18)
        #expect(Appearance.radius(["radius": 100]) == 48)
    }

    @Test func theDashboardsWordsForWaiting() {
        #expect(Appearance.loaderText(nil, moment: "component") == "Loading…")
        let text: [String: Any] = ["thinking": "  One sec  "]
        let loader: [String: Any] = ["text": text]
        #expect(Appearance.loaderText(["loader": loader], moment: "thinking") == "One sec")
        #expect(Appearance.prefersDark(["theme": "dark"], deviceIsDark: false))
        #expect(!Appearance.prefersDark(["theme": "light"], deviceIsDark: true))
        #expect(Appearance.prefersDark(nil, deviceIsDark: true))
    }
}

@MainActor
@Suite struct GraineInAppTests {
    private func makeGraine(variables: [String: Any] = [:]) -> GraineInApp {
        // Never configure()d: no network, no lifecycle observers.
        GraineInApp(config: GraineConfig(baseUrl: "https://example.invalid", publishableKey: "pk_test", variables: variables))
    }

    /// One action, run the way the page's request runs it, awaited.
    private func run(_ graine: GraineInApp, _ name: String, _ arguments: [String: Any] = [:]) async -> GraineActionResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<GraineActionResult, Never>) in
            graine.executeAction(name: name, arguments: arguments) { result in
                continuation.resume(returning: result)
            }
        }
    }

    @Test func anUnknownActionIsRefusedNotIgnored() async {
        let result = await run(makeGraine(), "fly")
        #expect(result.status == .refused)
        #expect(result.message == "This app build does not implement \"fly\".")
    }

    @Test func aRegisteredActionRunsWithItsArguments() async {
        let graine = makeGraine()
        graine.registerAction("set_tenure") { args in
            .ok("Tenure set to \(args["months"] as? Int ?? 0)")
        }
        let result = await run(graine, "set_tenure", ["months": 24])
        #expect(result.status == .ok)
        #expect(result.message == "Tenure set to 24")
    }

    @Test func aHandlerThatThrowsAnswersErrorWithWhatWentWrong() async {
        struct Locked: LocalizedError { var errorDescription: String? { "the form is locked" } }
        let graine = makeGraine()
        graine.registerAction("submit") { _ in throw Locked() }
        let result = await run(graine, "submit")
        #expect(result.status == .error)
        #expect(result.message == "the form is locked")
    }

    @Test func aDeferredHandlerMayAnswerFromAnyThreadAndOnlyOnce() async {
        let graine = makeGraine()
        graine.registerAction("upload", deferred: { _, done in
            DispatchQueue.global().async {
                done(.ok("uploaded"))
                done(.error("a second answer is ignored"))
            }
        })
        var onMain = false
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<GraineActionResult, Never>) in
            graine.executeAction(name: "upload", arguments: [:]) { result in
                onMain = Thread.isMainThread
                continuation.resume(returning: result)
            }
        }
        #expect(onMain)
        #expect(result.message == "uploaded")
        // The second answer must not reach anyone: give it the time it would need.
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    @Test func unregisteringRemovesOnlyItsOwnHandler() {
        let graine = makeGraine()
        let first = graine.registerAction("x") { _ in .ok() }
        graine.registerAction("x") { _ in .ok("second") }
        first()   // stale: a later registration replaced it
        #expect(graine.checkActions().undeclared == ["x"])
        let second = graine.registerAction("y") { _ in .ok() }
        second()
        #expect(graine.checkActions().undeclared == ["x"])
    }

    @Test func variablesFollowTheOnePrecedence() {
        let graine = makeGraine(variables: ["brand": "Acme", "plan": "Free"])
        var heard: [String: String] = [:]
        let stop = graine.onVariables { heard = $0 }
        graine.setVariables(["plan": "Plus"])
        #expect(heard["plan"] == "Plus")
        graine.identify(["plan": "Pro"])
        #expect(graine.currentVariables() == ["brand": "Acme", "plan": "Pro"])
        #expect(heard["plan"] == "Pro")
        stop()
    }

    @Test func identityAloneIsWorthAFrameAndSeqOnlyGoesUp() throws {
        let graine = makeGraine()
        graine.identify(["name": "Asha", "phone": "9876543210"])
        let f1 = try #require(graine.currentContextFrame())
        let user = (f1["context"] as? [String: Any])?["user"] as? [String: Any]
        #expect(user?["phone"] as? String == "[PHONE]")
        let f2 = try #require(graine.currentContextFrame())
        #expect((f2["seq"] as? Int ?? 0) == (f1["seq"] as? Int ?? 0) + 1)
    }

    @Test func recentEventsKeepTheLastTen() throws {
        let graine = makeGraine()
        for i in 0..<15 { graine.track("e\(i)") }
        let frame = try #require(graine.currentContextFrame())
        let events = try #require((frame["context"] as? [String: Any])?["recent_events"] as? [[String: Any]])
        #expect(events.count == 10)
        #expect(events.first?["name"] as? String == "e5")
    }

    @Test func anUnchangedScreenIsNotResentAndABurstIsCoalesced() async throws {
        let graine = makeGraine()
        var frames: [[String: Any]] = []
        let stop = graine.onContext { frames.append($0) }
        graine.setScreen(GraineScreen(screen: "a"))
        #expect(frames.count == 1, "the first frame goes at once")
        graine.setScreen(GraineScreen(screen: "a"))
        graine.setScreen(GraineScreen(screen: "b"))
        graine.setScreen(GraineScreen(screen: "c"))
        #expect(frames.count == 1, "inside the window: held")
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(frames.count == 2, "one trailing frame for the whole burst")
        #expect((frames.last?["context"] as? [String: Any])?["screen"] as? String == "c")
        stop()
    }
}

/*
 * Back in the foreground, the page is told to warm — when it is ready to hear
 * it, and never during a call. The same rule as the React Native launcher
 * (sdk/inapp/test/render/foreground-warm.test.mjs) and Android's WarmTest.
 */
@Suite struct WarmTests {
    @Test func anIdleReadyPageIsWarmed() {
        #expect(Warm.onForeground(ready: true, startedCall: false, connected: false, connecting: false))
    }

    @Test func aPageNotYetReadyIsNotToldAnything() {
        #expect(!Warm.onForeground(ready: false, startedCall: false, connected: false, connecting: false))
    }

    @Test func aCallStartingOrUnderwayIsNeverRewarmed() {
        #expect(!Warm.onForeground(ready: true, startedCall: true, connected: false, connecting: false))
        #expect(!Warm.onForeground(ready: true, startedCall: false, connected: false, connecting: true))
        #expect(!Warm.onForeground(ready: true, startedCall: false, connected: true, connecting: false))
    }
}
