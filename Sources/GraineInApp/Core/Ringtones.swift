import Foundation

/**
 * THE BRAND'S RING — `call.ringtone` `graine` or `soft`, the tone patterns of
 * contract/design.json → `ringtones` (theme.ts `RINGTONES`), synthesised here:
 * each note a `wave` (sine or triangle) at `hz` (0 is a rest) for `ms`, at
 * `gain` of full scale, rising linearly over its first 10 ms and falling over
 * its last 40 ms; the notes in order, then `pauseMs` of silence. Mono, 16-bit.
 *
 * On iOS the ring is CallKit's, and CallKit plays `ringtoneSound` by file name
 * and loops it; the SDK cannot add a file to the app's bundle, so it writes one
 * cycle of the pattern to the app's Library/Sounds — where the system also
 * looks for sounds by name — and names that. Should a system not find it there,
 * CallKit rings with the phone's own ringtone, which is `system` anyway.
 */
enum Ringtones {
    struct Note: Equatable {
        let hz: Double
        let ms: Double
    }

    struct Pattern: Equatable {
        let wave: String
        let gain: Double
        let notes: [Note]
        let pauseMs: Double
    }

    /// design.json `ringtones`, pinned by the contract tests.
    static let patterns: [String: Pattern] = [
        "graine": Pattern(wave: "sine", gain: 0.5, notes: [
            Note(hz: 659.25, ms: 150), Note(hz: 987.77, ms: 230), Note(hz: 0, ms: 110),
            Note(hz: 659.25, ms: 150), Note(hz: 987.77, ms: 230),
        ], pauseMs: 1_500),
        "soft": Pattern(wave: "triangle", gain: 0.35, notes: [
            Note(hz: 523.25, ms: 420), Note(hz: 783.99, ms: 560),
        ], pauseMs: 2_000),
    ]

    static let sampleRate = 22_050
    static let attackMs = 10.0
    static let releaseMs = 40.0

    /// One cycle of the pattern — its notes, then its pause — as 16-bit samples.
    static func samples(_ pattern: Pattern, rate: Int = sampleRate) -> [Int16] {
        var out: [Int16] = []
        let r = Double(rate)
        for note in pattern.notes {
            let count = Int((note.ms / 1_000 * r).rounded())
            let attack = attackMs / 1_000 * r
            let release = releaseMs / 1_000 * r
            for i in 0..<count {
                guard note.hz > 0 else { out.append(0); continue }
                let t = Double(i) / r
                let phase = (t * note.hz).truncatingRemainder(dividingBy: 1)
                let wave: Double
                if pattern.wave == "triangle" {
                    wave = 1 - 4 * abs(phase - 0.5) // 1 at the cycle's start, -1 at its middle
                } else {
                    wave = sin(2 * Double.pi * phase)
                }
                let x = Double(i)
                let envelope = min(1, x / max(1, attack), Double(count - 1 - i) / max(1, release))
                out.append(Int16((wave * pattern.gain * max(0, envelope) * 32_767).rounded()))
            }
        }
        out += [Int16](repeating: 0, count: Int((pattern.pauseMs / 1_000 * r).rounded()))
        return out
    }

    /// A WAV file (RIFF, PCM, mono, 16-bit little-endian) of those samples.
    static func wav(_ samples: [Int16], rate: Int = sampleRate) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    /// The file name CallKit is given for a pattern; versioned, so a changed pattern is a new file.
    static func fileName(_ name: String) -> String {
        "graine-ringtone-\(name)-v1.wav"
    }

    /**
     * The pattern's sound file in `directory` (Library/Sounds by default),
     * written once. Nil for `system`, an unknown name, or a file that could not
     * be written — then the phone's own ringtone.
     */
    static func soundFile(_ name: String, directory: URL? = nil) -> String? {
        guard let pattern = patterns[name] else { return nil }
        let folder = directory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sounds", isDirectory: true)
        guard let dir = folder else { return nil }
        let file = dir.appendingPathComponent(fileName(name))
        if FileManager.default.fileExists(atPath: file.path) { return fileName(name) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try wav(samples(pattern)).write(to: file, options: [.atomic])
            return fileName(name)
        } catch {
            GraineLog.warning("The ringtone could not be written; calls ring with the phone's own: \(GraineInApp.describe(error))")
            return nil
        }
    }
}

/**
 * THE UPCOMING-CALLS CARD's rules (DESIGN.md "Chat window"): which booked
 * calls it lists — still to ring, with a time, soonest first, at most three —
 * and how a time reads in the customer's own zone and words: "Today, 5:30 PM",
 * "Tomorrow, 9:00 AM", else the weekday and date ("Tue 14 Oct, 10:00 AM").
 */
enum UpcomingCalls {
    static let limit = 3

    /// Still to come (scheduled, or ringing now), with a time, soonest first, at most three.
    static func shown(_ calls: [GraineScheduledCall]) -> [GraineScheduledCall] {
        let timed = calls.compactMap { call in call.at.map { (call, $0) } }.filter { $0.0.isUpcoming }
        return timed.sorted { $0.1 < $1.1 }.prefix(limit).map { $0.0 }
    }

    static func title(count: Int) -> String {
        count == 1 ? "Upcoming call" : "Upcoming calls"
    }

    static func label(_ at: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        var cal = calendar
        cal.locale = locale
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = cal.timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        let clock = time.string(from: at)
        if cal.isDate(at, inSameDayAs: now) { return "Today, " + clock }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(at, inSameDayAs: tomorrow) {
            return "Tomorrow, " + clock
        }
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = cal.timeZone
        day.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return day.string(from: at) + ", " + clock
    }
}
