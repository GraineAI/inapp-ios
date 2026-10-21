import Foundation
import Testing
@testable import GraineInApp

/*
 * BOOKING SLOTS AND THE AGENT'S CALLING WINDOW (0.14.1): sdk/contract/booking-slots.json
 * run against this SDK's own code — never skipped.
 *
 *   window  the session's `calls.scheduling.callingWindow` → `callingWindow` as the
 *           session hands it to the app (GraineHostedCallsSettings, GraineSchedulingRules)
 *   slots   a device in the case's time zone, at its `now`, with its rules → the times
 *           `bookingSlots(day:)` offers on its day, instant for instant
 */
@Suite struct BookingSlotsContractTests {
    private func section(_ name: String) throws -> [[String: Any]] {
        let file = try ContractFile.load("booking-slots.json")
        let list = try #require(file[name] as? [[String: Any]], "booking-slots.json has no \(name)")
        #expect(!list.isEmpty, "booking-slots.json's \(name) is empty")
        return list
    }

    private static func instant(_ iso: String) throws -> Date {
        try #require(Scheduling.date(iso), "\(iso) is not a time")
    }

    private static func window(_ raw: Any?) throws -> GraineCallingWindow? {
        guard let o = raw as? [String: Any] else { return nil }
        let numbers = try #require(o["days"] as? [NSNumber])
        let start = try #require(o["start"] as? String)
        let end = try #require(o["end"] as? String)
        return GraineCallingWindow(start: start, end: end, days: numbers.map(\.intValue))
    }

    /// The session's `calls`, as the server sends it, with these scheduling rules.
    private static func session(_ scheduling: [String: Any]) -> GraineSessionConfig {
        GraineSessionConfig.parse(["agentId": "agent-1", "calls": ["hosted": true, "platforms": ["ios"], "scheduling": scheduling]])
    }

    @Test func theSessionsWindowIsReadAsTheContractSays() throws {
        let cases = try section("window")
        #expect(cases.count >= 15)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let expected = try Self.window(c["window"])
            // The wire value exactly as the file has it: null stays null.
            let config = Self.session(["usersCanBook": true, "callingWindow": c["wire"] ?? NSNull()])
            #expect(config.calls?.callingWindow == expected, "\(name)")
            #expect(config.schedulingRules.callingWindow == expected, "\(name)")
        }
        // No window at all in the session: none, and every other rule as it was.
        let without = Self.session(["usersCanBook": true, "minLeadMinutes": 10])
        #expect(without.schedulingRules.callingWindow == nil && without.schedulingRules.minLeadMinutes == 10)
    }

    @Test func eachDayOffersExactlyTheContractsTimes() throws {
        let cases = try section("slots")
        #expect(cases.count >= 15)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let zoneName = try #require(c["timeZone"] as? String)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: zoneName), "\(name)")
            let nowText = try #require(c["now"] as? String)
            let now = try Self.instant(nowText)
            let lead = try #require(c["minLeadMinutes"] as? NSNumber)
            let ahead = try #require(c["maxDaysAhead"] as? NSNumber)
            var scheduling: [String: Any] = ["usersCanBook": true, "minLeadMinutes": lead, "maxDaysAhead": ahead]
            scheduling["callingWindow"] = c["callingWindow"] ?? NSNull()
            let rules = Self.session(scheduling).schedulingRules
            // The day asked for: noon of that date on the device's clock.
            let dayText = try #require(c["day"] as? String)
            let ymd = dayText.split(separator: "-").compactMap { Int($0) }
            try #require(ymd.count == 3)
            let day = try #require(calendar.date(from: DateComponents(year: ymd[0], month: ymd[1], day: ymd[2], hour: 12)))
            let listed = try #require(c["slots"] as? [String])
            let expected = try listed.map(Self.instant)
            let offered = Booking.slots(rules, day: day, now: now, calendar: calendar)
            #expect(offered == expected, "\(name): \(offered.count) offered, \(expected.count) expected")
            // The sheet offers the same: its day's first and last time are the first and the last slot.
            let sheet = Booking.days(rules, now: now, calendar: calendar).first { $0.start == calendar.startOfDay(for: day) }
            #expect(sheet?.first == expected.first && sheet?.last == expected.last, "\(name): the sheet's day")
        }
    }
}
