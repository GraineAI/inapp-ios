import Foundation

/*
 * BOOKING A CALL FROM THE APP — the SDK's own booking sheet, as rules and
 * words (BOOKING-SHEET.md; contract §4.2, "(added by booking-native)"): when
 * an agent can be booked (`bookingAvailable`), which days and times the sheet
 * offers, what it says, and what a refusal reads as. Foundation only, so
 * `swift test` holds every rule on a Mac; UI/GraineBookingView.swift draws it.
 */
enum Booking {
    /// The sheet offers times on these steps, and the clock rounds to them.
    static let minuteStep = 5
    private static let step: TimeInterval = TimeInterval(minuteStep * 60)

    // MARK: Words — every SDK's, exactly

    static let title = "Book a call"
    static let dayLabel = "Day"
    static let timeLabel = "Time"
    static let reasonLabel = "What's it about? (optional)"
    static let bookButton = "Book call"
    static let doneButton = "Done"
    /// The chat window's row, and the card's button.
    static let chatRow = "Book a call"

    /// Under the title: who will ring.
    static func subtitle(callName: String) -> String {
        "\(callName) will call you"
    }

    /// The name that rings: the agent's call name (the session's `calls.callName`), else its chat title, else its heading.
    static func callName(_ named: String?, title: String?, heading: String?) -> String {
        for candidate in [named, title, heading] {
            if let words = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty { return words }
        }
        return "Assistant"
    }

    /// Once it is booked: "Booked — Acme will call you on Thu 16 Oct, 6:00 PM".
    static func bookedLine(callName: String, at: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        "Booked — \(callName) will call you on \(dateText(at, calendar: calendar, locale: locale)), \(clock(at, calendar: calendar, locale: locale))"
    }

    /// The device's zone, and the time picked in it: "Asia/Kolkata · Tue 14 Oct, 6:00 PM".
    static func zoneLine(_ at: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        "\(calendar.timeZone.identifier) · \(dateText(at, calendar: calendar, locale: locale)), \(clock(at, calendar: calendar, locale: locale))"
    }

    /**
     * A refusal, as the one line under the button. The counts are the agent's
     * own rules, so the line says what would work.
     */
    static func errorLine(_ code: GraineErrorCode, rules: GraineSchedulingRules) -> String {
        switch code {
        case .tooSoon: return "Pick a time at least \(count(rules.minLeadMinutes, "minute")) from now"
        case .tooFar: return "Pick a time within \(count(rules.maxDaysAhead, "day"))"
        case .outsideWindow: return "That time is outside the hours we can call — pick another"
        case .tooManyPending: return "You already have \(count(rules.maxPendingPerUser, "call")) booked — cancel one first"
        case .schedulingOff: return "Booking a call isn't available right now"
        case .identityRequired: return "Sign in to book a call"
        default: return "Couldn't book just now — try again"
        }
    }

    /// "5 minutes", "1 day": the spec's words, singular for one.
    private static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    // MARK: When booking is available

    /**
     * The one rule every SDK follows (BOOKING-SHEET.md §1): Graine can ring
     * this phone (`calls.hosted`, and `calls.platforms` empty or naming iOS),
     * the agent lets customers book (`calls.scheduling.usersCanBook`), and the
     * customer is identified with the trait the agent's Identity setting names
     * — else the booking is refused with `identity_required`.
     */
    static func available(calls: GraineHostedCallsSettings?, identified: Bool) -> Bool {
        blocked(calls: calls, identified: identified) == nil
    }

    /// Why the sheet cannot book now, as its line; nil when it can.
    static func blocked(calls: GraineHostedCallsSettings?, identified: Bool) -> String? {
        let rules = GraineSchedulingRules.from(calls)
        guard let calls = calls, calls.ringsThisPlatform, calls.usersCanBook else { return errorLine(.schedulingOff, rules: rules) }
        guard identified else { return errorLine(.identityRequired, rules: rules) }
        return nil
    }

    /// The agent's configuration has not loaded yet: no session, not even one kept from an earlier launch.
    static let notLoaded = "not_loaded"
    /// Graine does not ring this app's iPhones: no push credentials uploaded, or iOS is not among the platforms it rings.
    static let ringsNotSetUp = "rings_not_set_up"
    /// The agent does not let customers book calls (the booking's own refusal word, `scheduling_off`).
    static let schedulingOff = "scheduling_off"
    /// The customer is not identified with the trait the agent's Identity setting names.
    static let notIdentified = "not_identified"

    /**
     * Why this agent cannot be booked now, as a code — `available`'s rule,
     * first match wins: `not_loaded`, `rings_not_set_up`, `scheduling_off`,
     * `not_identified`; the same words on every SDK. Nil when it can.
     */
    static func unavailableReason(calls: GraineHostedCallsSettings?, loaded: Bool, identified: Bool) -> String? {
        guard loaded else { return notLoaded }
        guard let calls = calls, calls.ringsThisPlatform else { return ringsNotSetUp }
        guard calls.usersCanBook else { return schedulingOff }
        guard identified else { return notIdentified }
        return nil
    }

    // MARK: What the sheet offers

    /// The first time offered: `earliest(now)` rounded up to the next 5 minutes.
    static func first(_ rules: GraineSchedulingRules, now: Date) -> Date {
        roundUp(rules.earliest(now: now))
    }

    /// The last: `latest(now)`, on a 5-minute mark at or before it.
    static func last(_ rules: GraineSchedulingRules, now: Date) -> Date {
        roundDown(rules.latest(now: now))
    }

    static func roundUp(_ date: Date) -> Date {
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / step).rounded(.up) * step)
    }

    static func roundDown(_ date: Date) -> Date {
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / step).rounded(.down) * step)
    }

    /// One day the sheet offers: its chip's words, and the first and last time it has.
    struct Day: Equatable {
        /// Midnight, in the device's zone.
        let start: Date
        let first: Date
        let last: Date
        /// "Today", "Tomorrow", then the weekday and date ("Thu 16 Oct").
        let label: String
    }

    /**
     * Every day from the one `first(now)` falls on to the one `last(now)` falls
     * on, each holding only the times between the two — the chips — and, when
     * the agent has a calling window, only the times inside it: each day's
     * first and last time are its first and last inside the window, and a day
     * with no time left in it (or none inside the window) is not offered.
     */
    static func days(_ rules: GraineSchedulingRules, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> [Day] {
        let from = first(rules, now: now)
        let to = last(rules, now: now)
        guard from <= to else { return [] }
        let window = rules.callingWindow
        let clock = GraineCallingWindow.clock(for: calendar)
        var out: [Day] = []
        var start = calendar.startOfDay(for: from)
        let lastStart = calendar.startOfDay(for: to)
        while start <= lastStart, out.count < 400 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: start).map({ calendar.startOfDay(for: $0) }), next > start else { break }
            var dayFirst = max(from, start)
            var dayLast = min(to, roundDown(next.addingTimeInterval(-1)))
            if let window = window, dayFirst <= dayLast {
                // The first and the last 5-minute mark inside the window, read on the device's clock.
                while dayFirst <= dayLast, !window.allows(dayFirst, clock: clock) { dayFirst = dayFirst.addingTimeInterval(step) }
                while dayLast >= dayFirst, !window.allows(dayLast, clock: clock) { dayLast = dayLast.addingTimeInterval(-step) }
            }
            if dayFirst <= dayLast {
                out.append(Day(start: start, first: dayFirst, last: dayLast, label: dayLabel(start, now: now, calendar: calendar, locale: locale)))
            }
            start = next
        }
        return out
    }

    /**
     * Every time the sheet's picker offers on the day holding `day`, oldest
     * first: each 5-minute mark from that day's first time to its last — with
     * a calling window, only the marks inside it (its days, from its start up
     * to, not including, its end, on the device's clock). None for a day the
     * sheet does not offer.
     */
    static func slots(_ rules: GraineSchedulingRules, day: Date, now: Date, calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: day)
        guard let offered = days(rules, now: now, calendar: calendar).first(where: { $0.start == start }) else { return [] }
        let window = rules.callingWindow
        let clock = GraineCallingWindow.clock(for: calendar)
        var out: [Date] = []
        var at = offered.first
        var walked = 0
        // Bounded: a day has at most 25 hours (the night the clocks go back) of 5-minute marks.
        while at <= offered.last, walked <= 25 * 60 / minuteStep {
            if window?.allows(at, clock: clock) ?? true { out.append(at) }
            at = at.addingTimeInterval(step)
            walked += 1
        }
        return out
    }

    /// A time kept on the clock, moved onto `day`: the day's nearest when that day does not have it.
    static func move(_ time: Date, to day: Day, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        let same = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: day.start) ?? day.first
        return clamp(same, to: day)
    }

    /// Within the day's first and last time.
    static func clamp(_ time: Date, to day: Day) -> Date {
        min(max(time, day.first), day.last)
    }

    /// The chip's words: "Today", "Tomorrow", else the weekday and date in the device's words.
    static func dayLabel(_ day: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(day, inSameDayAs: tomorrow) { return "Tomorrow" }
        return dateText(day, calendar: calendar, locale: locale)
    }

    /// The weekday and date, as the upcoming-calls card writes them: "Thu 16 Oct" (in the device's words).
    static func dateText(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f.string(from: date)
    }

    /// The time, in the device's own style: "6:00 PM", "18:00".
    static func clock(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// What the field keeps: one line, at most the server's 120 characters.
    static func clipReason(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return CallWire.utf16Prefix(line, Scheduling.reasonLimit)
    }
}

/**
 * THE BOOKING SHEET'S STATE, apart from how it is drawn: the days and the
 * time on offer, what is picked, the reason, and what came of the booking —
 * one line under the button for a refusal, the booked call for a success.
 * The sheet hands `booked` back when it closes.
 */
struct BookingFlow: Equatable {
    enum Phase: Equatable {
        case picking
        case booking
        case booked(GraineScheduledCall)
    }

    private(set) var rules: GraineSchedulingRules
    private(set) var days: [Booking.Day]
    private(set) var dayIndex = 0
    /// The time picked: always one the picked day offers.
    private(set) var at: Date
    private(set) var reason: String
    private(set) var phase: Phase = .picking
    /// A refusal, in the sheet's words; nil when there is none to show.
    private(set) var errorLine: String?
    let calendar: Calendar
    let locale: Locale

    init(rules: GraineSchedulingRules, now: Date, reason: String? = nil, calendar: Calendar = .current, locale: Locale = .current) {
        self.rules = rules
        self.calendar = calendar
        self.locale = locale
        let days = Booking.days(rules, now: now, calendar: calendar, locale: locale)
        self.days = days
        at = days.first?.first ?? Booking.first(rules, now: now)
        self.reason = Booking.clipReason(reason ?? "")
    }

    /// The day picked; nil only when the rules offer none.
    var day: Booking.Day? { days.indices.contains(dayIndex) ? days[dayIndex] : nil }

    /// The booked call, once there is one: what the sheet hands back when it closes.
    var booked: GraineScheduledCall? {
        if case .booked(let call) = phase { return call }
        return nil
    }

    var isBooking: Bool { phase == .booking }

    /// A day's chip: the same time that day, or its nearest.
    mutating func pickDay(_ index: Int) {
        guard phase == .picking, days.indices.contains(index) else { return }
        dayIndex = index
        at = Booking.move(at, to: days[index], calendar: calendar)
        errorLine = nil
    }

    /// The time picker moved: kept within the picked day's times.
    mutating func pickTime(_ time: Date) {
        guard phase == .picking, let day = day else { return }
        at = Booking.move(time, to: day, calendar: calendar)
        errorLine = nil
    }

    mutating func setReason(_ text: String) {
        reason = Booking.clipReason(text)
    }

    /// The booking to send — the time and the reason (nil when blank) — or nil while one is on its way, or done.
    mutating func begin() -> (at: Date, reason: String?)? {
        guard phase == .picking, day != nil else { return nil }
        phase = .booking
        errorLine = nil
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return (at, why.isEmpty ? nil : why)
    }

    /// What came of it. A refusal stays in the sheet as one line; "too soon" moves the offer on to what `now` allows.
    mutating func finish(_ result: Result<GraineScheduledCall, Error>, now: Date) {
        switch result {
        case .success(let call):
            phase = .booked(call)
            errorLine = nil
        case .failure(let error):
            phase = .picking
            let code = (error as? GraineServiceError)?.code ?? .unknown("failed")
            if code == .tooSoon { refresh(now: now) }
            errorLine = Booking.errorLine(code, rules: rules)
        }
    }

    /// The offer again from `now` (time has passed, or the rules arrived): the same day and time where they still are.
    mutating func refresh(now: Date, rules next: GraineSchedulingRules? = nil) {
        guard phase != .booking else { return }
        if let next = next { rules = next }
        let wanted = at
        days = Booking.days(rules, now: now, calendar: calendar, locale: locale)
        guard !days.isEmpty else { return }
        let start = calendar.startOfDay(for: wanted)
        dayIndex = days.firstIndex { $0.start == start } ?? 0
        at = Booking.move(wanted, to: days[dayIndex], calendar: calendar)
    }
}
