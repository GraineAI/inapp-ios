import Foundation
import Testing
@testable import GraineInApp

/*
 * BOOKING A CALL FROM THE APP (BOOKING-SHEET.md §5): `bookingAvailable` for
 * each of its rules and per agent, what the sheet offers (today to the
 * furthest day, 5-minute steps between earliest and latest), each refusal as
 * its line, a booking that succeeds handing back the call, and the chat
 * window's "Book a call" only where booking is available and the design keeps
 * the booked-calls card. The sheet itself is iOS-only UI; its state is here.
 */

private let palette = GraineThemeTokens.Colors(
    background: "#FFFFFF", surface: "#F7F7F5", surfaceRaised: "#FFFFFF", text: "#101318", textMuted: "#5F6672",
    border: "#E5E4E0", accent: "#318CE7", onAccent: "#FFFFFF", accentSoft: "#E3EEFB", success: "#1FAD5B",
    warning: "#F5A524", danger: "#E5484D", userBubble: "#318CE7", userBubbleText: "#FFFFFF",
    agentBubble: "#F1F1EF", agentBubbleText: "#101318", scrim: "#000000"
)

/// A calendar in one zone, so the days and labels do not depend on the Mac running the tests.
private func kolkata() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    return calendar
}

/// A wall-clock time in Kolkata.
private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    kolkata().date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

private let gb = Locale(identifier: "en_GB")

private func bookable(_ extra: [String: Any] = [:]) -> [String: Any] {
    var scheduling: [String: Any] = ["usersCanBook": true, "minLeadMinutes": 5, "maxDaysAhead": 14, "maxPendingPerUser": 3]
    for (k, v) in extra { scheduling[k] = v }
    return ["calls": ["hosted": true, "platforms": ["ios", "android"], "callName": "Acme Care", "scheduling": scheduling]]
}

@Suite @MainActor struct BookingAvailableTests {
    @Test func everyRuleMustHold() {
        let cases: [(String, [String: Any], Bool)] = [
            ("hosted, iOS rung, users may book, identified", bookable(), true),
            ("no platforms named: every platform", ["calls": ["hosted": true, "scheduling": ["usersCanBook": true]]], true),
            ("Graine does not ring this app", ["calls": ["hosted": false, "scheduling": ["usersCanBook": true]]], false),
            ("Graine rings Android only", ["calls": ["hosted": true, "platforms": ["android"], "scheduling": ["usersCanBook": true]]], false),
            ("users may not book", ["calls": ["hosted": true, "scheduling": ["usersCanBook": false]]], false),
            ("calls without scheduling", ["calls": ["hosted": true]], false),
            ("an older server: no calls at all", [:], false),
        ]
        for (name, session, expected) in cases {
            let rig = PlatformRig()
            defer { rig.sandbox.clean() }
            rig.session(session)
            rig.graine.identify(["user_id": "P-1", "name": "Riya"])
            #expect(rig.graine.bookingAvailable == expected, "\(name)")
        }
    }

    @Test func theCustomerMustBeIdentifiedWithTheAgentsOwnTrait() {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        var session = bookable()
        session["identity"] = ["field": "patient_id", "devicesPerUser": 2]
        rig.session(session)
        #expect(!rig.graine.bookingAvailable, "nobody identified")
        #expect(rig.graine.bookingBlocked == "Sign in to book a call")
        rig.graine.identify(["user_id": "P-1"])
        #expect(!rig.graine.bookingAvailable, "identified, but not with the trait the agent names")
        rig.graine.identify(["patient_id": "MRN-000981"])
        #expect(rig.graine.bookingAvailable)
        #expect(rig.graine.bookingBlocked == nil)
        rig.graine.identify(["patient_id": "guest"])
        #expect(!rig.graine.bookingAvailable, "a placeholder is nobody")
        rig.graine.identify(nil)
        #expect(!rig.graine.bookingAvailable, "signed out")
    }

    @Test func beforeTheSessionNothingCanBeBooked() {
        let rig = PlatformRig()
        defer { rig.sandbox.clean() }
        rig.graine.identify(["user_id": "P-1"])
        #expect(!rig.graine.bookingAvailable)
        #expect(rig.graine.bookingBlocked == "Booking a call isn't available right now")
    }

    @Test func eachAgentAnswersForItself() {
        let registry = GraineAgentRegistry()
        let sandbox = Sandbox()
        defer { sandbox.clean() }
        let installs = MemoryInstallIdStore("3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        func agent(_ name: String, _ key: String) -> GraineInApp {
            let made = GraineInApp(
                config: GraineConfig(baseUrl: "https://www.graine.ai", publishableKey: key), installIds: installs,
                defaults: sandbox.defaults, sessionCache: SessionCache(directory: sandbox.folder, agent: name),
                network: RoutedNetwork(), chatScheduler: ManualScheduler(), name: name, registry: registry
            )
            registry.add(made)
            return made
        }
        let support = agent("default", "pk_test_support")
        let sales = agent("sales", "pk_test_sales")
        var salesSession = bookable()
        salesSession["agentId"] = "agent-sales"
        sales.finishSession(.success(GraineSessionConfig.parse(salesSession)))
        support.finishSession(.success(GraineSessionConfig.parse(["agentId": "agent-support", "calls": ["hosted": true]])))
        support.identify(["user_id": "P-1"])
        #expect(sales.bookingAvailable, "the person is the app's: identified on one agent, identified on both")
        #expect(!support.bookingAvailable, "the support agent does not let customers book")
        #expect(GraineObjC(graine: sales).bookingAvailable && !GraineObjC(graine: support).bookingAvailable, "the facade says the same")
    }
}

@Suite struct BookingOfferTests {
    private let rules = GraineSchedulingRules(usersCanBook: true, minLeadMinutes: 5, maxDaysAhead: 14, hostedRinging: true)

    @Test func theFirstTimeIsTheLeadRoundedUpToFiveMinutes() {
        #expect(Booking.first(rules, now: at(2026, 10, 14, 18, 3, 20)) == at(2026, 10, 14, 18, 10))
        #expect(Booking.first(rules, now: at(2026, 10, 14, 18, 0)) == at(2026, 10, 14, 18, 5), "already on a mark: kept")
        #expect(Booking.first(rules, now: at(2026, 10, 14, 18, 0, 1)) == at(2026, 10, 14, 18, 10))
        let long = GraineSchedulingRules(usersCanBook: true, minLeadMinutes: 90)
        #expect(Booking.first(long, now: at(2026, 10, 14, 18, 3)) == at(2026, 10, 14, 19, 35))
        #expect(Booking.first(rules, now: at(2026, 10, 14, 18, 3)) >= rules.earliest(now: at(2026, 10, 14, 18, 3)), "never before earliest")
    }

    @Test func theLastTimeIsLatestOnAFiveMinuteMark() {
        let now = at(2026, 10, 14, 18, 3, 20)
        #expect(Booking.last(rules, now: now) == at(2026, 10, 28, 18, 0))
        #expect(Booking.last(rules, now: now) <= rules.latest(now: now), "never after latest")
    }

    @Test func theDaysRunFromTodayToTheFurthestWithOnlyTheTimesAllowed() throws {
        let calendar = kolkata()
        let now = at(2026, 10, 14, 18, 3)
        let days = Booking.days(rules, now: now, calendar: calendar, locale: gb)
        #expect(days.count == 15, "today and 14 days ahead")
        #expect(days.map(\.label).prefix(2) == ["Today", "Tomorrow"])
        #expect(days[2].label == Booking.dateText(at(2026, 10, 16, 0, 0), calendar: calendar, locale: gb))
        #expect(days[2].label.contains("Fri") && days[2].label.contains("16") && days[2].label.contains("Oct"))
        #expect(days[0].first == at(2026, 10, 14, 18, 10) && days[0].last == at(2026, 10, 14, 23, 55))
        #expect(days[1].first == at(2026, 10, 15, 0, 0) && days[1].last == at(2026, 10, 15, 23, 55))
        #expect(days[14].first == at(2026, 10, 28, 0, 0) && days[14].last == at(2026, 10, 28, 18, 0))
        for day in days {
            #expect(day.first <= day.last)
            #expect(calendar.component(.minute, from: day.first) % 5 == 0 && calendar.component(.second, from: day.first) == 0)
        }
    }

    @Test func aDayWithNoTimeLeftIsNotOffered() {
        let calendar = kolkata()
        // 23:58: the lead runs past midnight, so the first day offered is tomorrow.
        let days = Booking.days(rules, now: at(2026, 10, 14, 23, 58), calendar: calendar, locale: gb)
        #expect(days.first?.label == "Tomorrow")
        #expect(days.first?.first == at(2026, 10, 15, 0, 5))
        let none = Booking.days(GraineSchedulingRules(usersCanBook: true, minLeadMinutes: 2, maxDaysAhead: 0), now: at(2026, 10, 14, 18, 3), calendar: calendar)
        #expect(none.isEmpty, "a window narrower than five minutes offers nothing")
    }

    @Test func pickingADayKeepsTheTimeWhereItCanAndClampsWhereItCannot() throws {
        let calendar = kolkata()
        var flow = BookingFlow(rules: rules, now: at(2026, 10, 14, 18, 3), calendar: calendar, locale: gb)
        #expect(flow.at == at(2026, 10, 14, 18, 10), "opens on the first time offered")
        flow.pickDay(1)
        #expect(flow.at == at(2026, 10, 15, 18, 10), "tomorrow, the same time")
        flow.pickTime(at(2026, 10, 15, 7, 30))
        #expect(flow.at == at(2026, 10, 15, 7, 30))
        flow.pickDay(0)
        #expect(flow.at == at(2026, 10, 14, 18, 10), "7:30 has passed today: the first time today has")
        flow.pickDay(14)
        flow.pickTime(at(2026, 10, 28, 21, 0))
        #expect(flow.at == at(2026, 10, 28, 18, 0), "after latest: the last time offered")
        flow.pickDay(99)
        #expect(flow.dayIndex == 14, "no such day: nothing changes")
    }

    @Test func theSheetsWordsAreTheSpecs() throws {
        var calendar = kolkata()
        calendar.locale = gb
        let six = at(2026, 10, 14, 18, 0)
        #expect(Booking.title == "Book a call")
        #expect(Booking.subtitle(callName: "Acme Care") == "Acme Care will call you")
        #expect(Booking.reasonLabel == "What's it about? (optional)")
        #expect(Booking.bookButton == "Book call")
        #expect(Booking.chatRow == "Book a call")
        let date = Booking.dateText(six, calendar: calendar, locale: gb)
        let clock = Booking.clock(six, calendar: calendar, locale: gb)
        #expect(date.contains("Wed") && date.contains("14") && date.contains("Oct"))
        #expect(Booking.zoneLine(six, calendar: calendar, locale: gb) == "Asia/Kolkata · \(date), \(clock)")
        #expect(Booking.bookedLine(callName: "Acme Care", at: six, calendar: calendar, locale: gb) == "Booked — Acme Care will call you on \(date), \(clock)")
        #expect(Booking.callName("Acme Care", title: "Aria", heading: "Help") == "Acme Care")
        #expect(Booking.callName("  ", title: "Aria", heading: "Help") == "Aria", "no call name: the chat's title")
        #expect(Booking.callName(nil, title: "", heading: "Help") == "Help")
        #expect(Booking.callName(nil, title: nil, heading: nil) == "Assistant")
    }

    @Test func theReasonIsOneLineOfAtMost120Characters() {
        var flow = BookingFlow(rules: rules, now: Date(), reason: "Finish my\nKYC")
        #expect(flow.reason == "Finish my KYC")
        flow.setReason(String(repeating: "a", count: 300))
        #expect(flow.reason.count == 120)
        flow.setReason("   ")
        let blank = flow.begin()
        #expect(blank != nil && blank?.reason == nil, "a blank reason is no reason")
    }
}

@Suite struct BookingRefusalTests {
    @Test func eachRefusalIsItsLine() {
        let rules = GraineSchedulingRules(usersCanBook: true, minLeadMinutes: 15, maxDaysAhead: 7, maxPendingPerUser: 3)
        let lines: [(GraineErrorCode, String)] = [
            (.tooSoon, "Pick a time at least 15 minutes from now"),
            (.tooFar, "Pick a time within 7 days"),
            (.outsideWindow, "That time is outside the hours we can call — pick another"),
            (.tooManyPending, "You already have 3 calls booked — cancel one first"),
            (.schedulingOff, "Booking a call isn't available right now"),
            (.identityRequired, "Sign in to book a call"),
            (.rateLimited, "Couldn't book just now — try again"),
            (.unavailable, "Couldn't book just now — try again"),
            (.network, "Couldn't book just now — try again"),
            (.unknown("server_error"), "Couldn't book just now — try again"),
        ]
        for (code, line) in lines {
            #expect(Booking.errorLine(code, rules: rules) == line, "\(code)")
        }
        let one = GraineSchedulingRules(usersCanBook: true, minLeadMinutes: 1, maxDaysAhead: 1, maxPendingPerUser: 1)
        #expect(Booking.errorLine(.tooSoon, rules: one) == "Pick a time at least 1 minute from now")
        #expect(Booking.errorLine(.tooFar, rules: one) == "Pick a time within 1 day")
        #expect(Booking.errorLine(.tooManyPending, rules: one) == "You already have 1 call booked — cancel one first")
    }

    @Test func aRefusalStaysInTheSheetAndTooSoonMovesTheOfferOn() throws {
        let rules = GraineSchedulingRules(usersCanBook: true, minLeadMinutes: 5, maxDaysAhead: 14, hostedRinging: true)
        let calendar = kolkata()
        var flow = BookingFlow(rules: rules, now: at(2026, 10, 14, 18, 3), calendar: calendar, locale: gb)
        let first = flow.begin()
        #expect(first != nil && flow.isBooking)
        let second = flow.begin()
        #expect(second == nil, "one booking at a time")
        flow.pickDay(1)
        #expect(flow.dayIndex == 0, "nothing moves while it books")
        flow.finish(.failure(GraineServiceError(code: .outsideWindow, message: "x", status: 422)), now: at(2026, 10, 14, 18, 4))
        #expect(flow.phase == .picking)
        #expect(flow.errorLine == "That time is outside the hours we can call — pick another")
        flow.pickTime(at(2026, 10, 14, 19, 0))
        #expect(flow.errorLine == nil, "a new pick clears the line")
        flow.pickTime(at(2026, 10, 14, 18, 10))
        let again = flow.begin()
        #expect(again?.at == at(2026, 10, 14, 18, 10))
        // Twenty minutes later, 18:10 is too soon: the line says so and the offer starts at what now allows.
        flow.finish(.failure(GraineServiceError(code: .tooSoon, message: "x")), now: at(2026, 10, 14, 18, 23))
        #expect(flow.errorLine == "Pick a time at least 5 minutes from now")
        #expect(flow.at == at(2026, 10, 14, 18, 30))
        #expect(flow.days.first?.first == at(2026, 10, 14, 18, 30))
        flow.finish(.failure(URLError(.notConnectedToInternet)), now: Date())
        #expect(flow.errorLine == "Couldn't book just now — try again", "anything else: try again")
    }
}

@Suite @MainActor struct BookingFlowTests {
    private func tomorrowRig() -> PlatformRig {
        let rig = PlatformRig()
        rig.session(bookable(["minLeadMinutes": 5, "maxDaysAhead": 14]))
        rig.graine.identify(["user_id": "P-1"])
        return rig
    }

    /// What the sheet does on "Book call": begin, ask, finish.
    private func book(_ flow: inout BookingFlow, on graine: GraineInApp) async {
        guard let request = flow.begin() else { return }
        do {
            flow.finish(.success(try await graine.scheduleCall(at: request.at, reason: request.reason)), now: Date())
        } catch {
            flow.finish(.failure(error), now: Date())
        }
    }

    @Test func aBookingThatSucceedsHandsBackTheCall() async throws {
        let rig = tomorrowRig()
        defer { rig.sandbox.clean() }
        var flow = BookingFlow(rules: rig.graine.schedulingRules, now: Date(), reason: "Help with my KYC")
        flow.pickDay(1)
        let when = flow.at
        rig.network.replies["/api/embed/calls/schedule"] = (201, #"{"call":{"id":"s1","at":"\#(Scheduling.isoTime(when))","status":"scheduled","source":"sdk","reason":"Help with my KYC"}}"#)
        await book(&flow, on: rig.graine)
        let call = try #require(flow.booked)
        #expect(call == GraineScheduledCall(id: "s1", at: when, status: .scheduled, source: .app, reason: "Help with my KYC"))
        #expect(flow.errorLine == nil)
        let body = try #require(rig.network.bodies("/api/embed/calls/schedule").first)
        #expect(body["at"] as? String == Scheduling.isoTime(when))
        #expect(body["reason"] as? String == "Help with my KYC")
        #expect((body["identity"] as? [String: Any])?["value"] as? String == "P-1")
        let more = flow.begin()
        #expect(more == nil, "booked: nothing more to book in this sheet")
    }

    @Test func eachRefusalFromGraineIsItsLineInTheSheet() async throws {
        let refusals: [(Int, String, String)] = [
            (422, "outside_window", "That time is outside the hours we can call — pick another"),
            (409, "too_many_pending", "You already have 3 calls booked — cancel one first"),
            (400, "identity_required", "Sign in to book a call"),
            (403, "scheduling_off", "Booking a call isn't available right now"),
            (429, "rate_limited", "Couldn't book just now — try again"),
            (503, "unavailable", "Couldn't book just now — try again"),
        ]
        for (status, code, line) in refusals {
            let rig = tomorrowRig()
            defer { rig.sandbox.clean() }
            var flow = BookingFlow(rules: rig.graine.schedulingRules, now: Date())
            flow.pickDay(1)
            rig.network.replies["/api/embed/calls/schedule"] = (status, #"{"error":"Refused.","code":"\#(code)"}"#)
            await book(&flow, on: rig.graine)
            #expect(flow.booked == nil, "\(code)")
            #expect(flow.phase == .picking, "\(code): the customer can pick again")
            #expect(flow.errorLine == line, "\(code)")
        }
        // No answer at all.
        let rig = tomorrowRig()
        defer { rig.sandbox.clean() }
        var flow = BookingFlow(rules: rig.graine.schedulingRules, now: Date())
        flow.pickDay(1)
        rig.network.replies["/api/embed/calls/schedule"] = (0, nil)
        await book(&flow, on: rig.graine)
        #expect(flow.errorLine == "Couldn't book just now — try again")
    }
}

@Suite struct BookingChatRowTests {
    @Test func theRowShowsOnlyWhereBookingIsAvailableAndTheCardIsKept() throws {
        let kept = try #require(SurfaceTokens.chat([:], colors: palette))
        let off = try #require(SurfaceTokens.chat(["showUpcomingCalls": false], colors: palette))
        // No calls booked: the compact row stands where the card would be.
        let alone = ChatPieces.of([], chat: kept, upcomingCount: 0, bookable: true)
        #expect(alone.book && !alone.upcoming)
        // Calls booked: in the card, under them.
        let inCard = ChatPieces.of([], chat: kept, upcomingCount: 2, bookable: true)
        #expect(inCard.book && inCard.upcoming)
        #expect(!ChatPieces.of([], chat: kept, upcomingCount: 2, bookable: false).book, "booking not available: no row")
        #expect(!ChatPieces.of([], chat: kept, upcomingCount: 0).book, "the default is no row")
        #expect(!ChatPieces.of([], chat: off, upcomingCount: 2, bookable: true).book, "the design hides the booked-calls card: no row either")
        #expect(ChatPieces.of([], chat: nil, upcomingCount: 0, bookable: true).book, "an older server: the card is on, so the row is")
    }
}
