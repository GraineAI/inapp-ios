import Foundation

/**
 * One drawing command of a launcher glyph, in the glyph's own 24×24 box, with
 * every coordinate absolute. Four kinds are enough for anything SVG path data
 * can say: quadratics become cubics exactly, and arcs become cubics to well
 * under a hundredth of a unit.
 */
enum GlyphSegment: Equatable {
    case move(x: Double, y: Double)
    case line(x: Double, y: Double)
    case cubic(x1: Double, y1: Double, x2: Double, y2: Double, x: Double, y: Double)
    case close
}

/**
 * THE LAUNCHER GLYPH, DRAWN FROM ITS PATH DATA — not fetched as a picture.
 *
 * The design carries each glyph as a 24×24 SVG path (`icons.launcher.path`).
 * The glyph endpoint would also send it as a PNG, and GraineGlyph builds that
 * URL for hosts that want it; this SDK draws the path instead, because the
 * launcher is the first thing a customer sees: parsed, it is on screen in the
 * first frame, offline included, sharp at every size, in exactly `onAccent` at
 * exactly `icons.stroke` — with no request, no cache to manage, and no failure
 * that ends in a blank button.
 *
 * The full path grammar: M L H V C S Q T A Z, absolute and relative, implicit
 * repeats (and a moveto's extra pairs being linetos), numbers written the way
 * minifiers write them ("0-.96", ".5.5", "1e-3"), and arc flags with no space
 * after them ("a1 1 0 011 1"). Anything it cannot read is nil — the launcher
 * then shows the brand's logo, never half a drawing.
 */
enum GlyphPath {

    private static let cacheLock = NSLock()
    private static var cache: [String: [GlyphSegment]] = [:]
    private static var unreadable: Set<String> = []

    /// `parse`, remembered: a view asks on every frame of an animation, and a design has a handful of glyphs.
    static func cached(_ data: String) -> [GlyphSegment]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[data] { return hit }
        if unreadable.contains(data) { return nil }
        // Bounded: a long-lived process meeting many designs keeps only the latest. Room for every one of the SDK's
        // own icons (nineteen, most with two paths) and a few launcher glyphs, so drawing them never starts over.
        if cache.count + unreadable.count >= 64 {
            cache.removeAll()
            unreadable.removeAll()
        }
        guard let parsed = parse(data) else {
            unreadable.insert(data)
            return nil
        }
        cache[data] = parsed
        return parsed
    }

    static func parse(_ data: String) -> [GlyphSegment]? {
        var scanner = Scanner(Array(data.utf8))
        var out: [GlyphSegment] = []
        var current = (x: 0.0, y: 0.0)
        var start = (x: 0.0, y: 0.0)
        // The last control point, and whether the previous command could leave one to reflect.
        var lastCubic: (x: Double, y: Double)?
        var lastQuad: (x: Double, y: Double)?

        scanner.skipSeparators()
        while !scanner.atEnd {
            guard var command = scanner.command() else { return nil }
            if out.isEmpty && command != UInt8(ascii: "M") && command != UInt8(ascii: "m") { return nil }

            if command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                out.append(.close)
                current = start
                lastCubic = nil
                lastQuad = nil
                scanner.skipSeparators()
                continue
            }

            repeat {
                let relative = command >= UInt8(ascii: "a")
                let upper = relative ? command - 32 : command
                let ox = relative ? current.x : 0
                let oy = relative ? current.y : 0
                var nextCubic: (x: Double, y: Double)?
                var nextQuad: (x: Double, y: Double)?

                switch upper {
                case UInt8(ascii: "M"):
                    guard let p = scanner.numbers(2) else { return nil }
                    current = (ox + p[0], oy + p[1])
                    start = current
                    out.append(.move(x: current.x, y: current.y))
                    // A moveto's extra pairs are linetos, relative if it was.
                    command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")

                case UInt8(ascii: "L"):
                    guard let p = scanner.numbers(2) else { return nil }
                    current = (ox + p[0], oy + p[1])
                    out.append(.line(x: current.x, y: current.y))

                case UInt8(ascii: "H"):
                    guard let p = scanner.numbers(1) else { return nil }
                    current = (ox + p[0], current.y)
                    out.append(.line(x: current.x, y: current.y))

                case UInt8(ascii: "V"):
                    guard let p = scanner.numbers(1) else { return nil }
                    current = (current.x, oy + p[0])
                    out.append(.line(x: current.x, y: current.y))

                case UInt8(ascii: "C"):
                    guard let p = scanner.numbers(6) else { return nil }
                    let c2 = (x: ox + p[2], y: oy + p[3])
                    let end = (x: ox + p[4], y: oy + p[5])
                    out.append(.cubic(x1: ox + p[0], y1: oy + p[1], x2: c2.x, y2: c2.y, x: end.x, y: end.y))
                    current = end
                    nextCubic = c2

                case UInt8(ascii: "S"):
                    guard let p = scanner.numbers(4) else { return nil }
                    // The first control point mirrors the last one, when the last command left one.
                    let c1 = lastCubic.map { (x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                    let c2 = (x: ox + p[0], y: oy + p[1])
                    let end = (x: ox + p[2], y: oy + p[3])
                    out.append(.cubic(x1: c1.x, y1: c1.y, x2: c2.x, y2: c2.y, x: end.x, y: end.y))
                    current = end
                    nextCubic = c2

                case UInt8(ascii: "Q"):
                    guard let p = scanner.numbers(4) else { return nil }
                    let q = (x: ox + p[0], y: oy + p[1])
                    let end = (x: ox + p[2], y: oy + p[3])
                    out.append(quadratic(from: current, control: q, to: end))
                    current = end
                    nextQuad = q

                case UInt8(ascii: "T"):
                    guard let p = scanner.numbers(2) else { return nil }
                    let q = lastQuad.map { (x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                    let end = (x: ox + p[0], y: oy + p[1])
                    out.append(quadratic(from: current, control: q, to: end))
                    current = end
                    nextQuad = q

                case UInt8(ascii: "A"):
                    guard let radii = scanner.numbers(3),
                          let large = scanner.flag(), let sweep = scanner.flag(),
                          let p = scanner.numbers(2) else { return nil }
                    let end = (x: ox + p[0], y: oy + p[1])
                    out.append(contentsOf: arc(
                        from: current, rx: radii[0], ry: radii[1], rotation: radii[2],
                        largeArc: large, sweep: sweep, to: end
                    ))
                    current = end

                default:
                    return nil
                }
                lastCubic = nextCubic
                lastQuad = nextQuad
                scanner.skipSeparators()
            } while scanner.startsNumber()
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Curves

    /// A quadratic is a cubic with its control points two thirds of the way to the quadratic's one.
    private static func quadratic(
        from p0: (x: Double, y: Double), control q: (x: Double, y: Double), to p: (x: Double, y: Double)
    ) -> GlyphSegment {
        .cubic(
            x1: p0.x + 2.0 / 3.0 * (q.x - p0.x), y1: p0.y + 2.0 / 3.0 * (q.y - p0.y),
            x2: p.x + 2.0 / 3.0 * (q.x - p.x), y2: p.y + 2.0 / 3.0 * (q.y - p.y),
            x: p.x, y: p.y
        )
    }

    /**
     * An elliptical arc as cubics: the SVG specification's endpoint-to-centre
     * conversion (implementation notes, F.6.5–F.6.6), then one cubic per
     * quarter turn or less with the standard 4/3·tan(θ/4) handles. Radii too
     * small to reach the end point are scaled up, as the specification says;
     * a zero radius is a straight line; an arc to where it starts is nothing.
     */
    static func arc(
        from p1: (x: Double, y: Double), rx rxIn: Double, ry ryIn: Double, rotation: Double,
        largeArc: Bool, sweep: Bool, to p2: (x: Double, y: Double)
    ) -> [GlyphSegment] {
        if p1.x == p2.x && p1.y == p2.y { return [] }
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if rx == 0 || ry == 0 { return [.line(x: p2.x, y: p2.y)] }

        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (p1.x - p2.x) / 2
        let dy = (p1.y - p2.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let root = denominator == 0 ? 0 : max(0, numerator / denominator).squareRoot()
        let sign: Double = largeArc != sweep ? 1 : -1
        let cxp = sign * root * rx * y1p / ry
        let cyp = sign * root * -ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let ux = (x1p - cxp) / rx
        let uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx
        let vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        // Quarter turns, rounded up — with a hair of slack, so a half circle is two pieces, not three.
        let pieces = max(1, Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
        let step = delta / Double(pieces)
        let handle = 4.0 / 3.0 * tan(step / 4)

        // A point on the unit circle, onto the ellipse.
        func map(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            (cx + rx * cosPhi * x - ry * sinPhi * y, cy + rx * sinPhi * x + ry * cosPhi * y)
        }
        var out: [GlyphSegment] = []
        var a = theta1
        for i in 0..<pieces {
            let b = a + step
            let c1 = map(cos(a) - handle * sin(a), sin(a) + handle * cos(a))
            let c2 = map(cos(b) + handle * sin(b), sin(b) - handle * cos(b))
            // The last piece ends exactly where the arc was asked to, not a rounding error away.
            let end = i == pieces - 1 ? p2 : map(cos(b), sin(b))
            out.append(.cubic(x1: c1.x, y1: c1.y, x2: c2.x, y2: c2.y, x: end.x, y: end.y))
            a = b
        }
        return out
    }

    // MARK: - Reading the text

    private struct Scanner {
        let bytes: [UInt8]
        var i = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { i >= bytes.count }

        mutating func skipSeparators() {
            while i < bytes.count, Scanner.isSeparator(bytes[i]) { i += 1 }
        }

        /// A command letter, consumed; nil for anything else.
        mutating func command() -> UInt8? {
            guard i < bytes.count, Scanner.isCommand(bytes[i]) else { return nil }
            defer { i += 1 }
            return bytes[i]
        }

        /// Whether a number starts here (after separators): an implicit repeat of the last command.
        mutating func startsNumber() -> Bool {
            skipSeparators()
            guard i < bytes.count else { return false }
            let c = bytes[i]
            return Scanner.isDigit(c) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".")
        }

        mutating func numbers(_ count: Int) -> [Double]? {
            var out: [Double] = []
            out.reserveCapacity(count)
            for _ in 0..<count {
                guard let n = number() else { return nil }
                out.append(n)
            }
            return out
        }

        /// An arc flag: exactly one "0" or "1", which may be followed directly by the next value.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < bytes.count else { return nil }
            switch bytes[i] {
            case UInt8(ascii: "0"): i += 1; return false
            case UInt8(ascii: "1"): i += 1; return true
            default: return nil
            }
        }

        /**
         * One number, the way path data writes them: an optional sign, digits
         * with at most one point, an optional exponent. A second point or a
         * sign ends it and starts the next — "0-.96" is two numbers, ".5.5" too.
         */
        mutating func number() -> Double? {
            skipSeparators()
            let begin = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { i += 1 }
            var digits = 0
            while i < bytes.count, Scanner.isDigit(bytes[i]) { i += 1; digits += 1 }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                while i < bytes.count, Scanner.isDigit(bytes[i]) { i += 1; digits += 1 }
            }
            guard digits > 0 else {
                i = begin
                return nil
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                var j = i + 1
                if j < bytes.count, bytes[j] == UInt8(ascii: "-") || bytes[j] == UInt8(ascii: "+") { j += 1 }
                var exponentDigits = 0
                while j < bytes.count, Scanner.isDigit(bytes[j]) { j += 1; exponentDigits += 1 }
                if exponentDigits > 0 { i = j }
            }
            guard let text = String(bytes: bytes[begin..<i], encoding: .ascii), let value = Double(text), value.isFinite else {
                return nil
            }
            return value
        }

        static func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }

        static func isSeparator(_ c: UInt8) -> Bool {
            c == UInt8(ascii: " ") || c == UInt8(ascii: ",") || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C
        }

        static func isCommand(_ c: UInt8) -> Bool {
            switch c {
            case UInt8(ascii: "M"), UInt8(ascii: "m"), UInt8(ascii: "L"), UInt8(ascii: "l"),
                 UInt8(ascii: "H"), UInt8(ascii: "h"), UInt8(ascii: "V"), UInt8(ascii: "v"),
                 UInt8(ascii: "C"), UInt8(ascii: "c"), UInt8(ascii: "S"), UInt8(ascii: "s"),
                 UInt8(ascii: "Q"), UInt8(ascii: "q"), UInt8(ascii: "T"), UInt8(ascii: "t"),
                 UInt8(ascii: "A"), UInt8(ascii: "a"), UInt8(ascii: "Z"), UInt8(ascii: "z"):
                return true
            default:
                return false
            }
        }
    }
}
