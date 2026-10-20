import Foundation

/*
 * SAFE FORMATTING — the little Markdown the agent's words may carry, and
 * nothing else (contract/DESIGN.md "Chat window v2" → Formatting): **bold**
 * (or __bold__), *italic* (or _italic_), `code`, [links](https://…) and bare
 * https:// links, lines starting "- ", "* " or "• " (a bullet) or "1. " /
 * "1) " (a numbered item), a "# heading" (drawn as a bold line), and line
 * breaks. Never HTML: text stays text. A link is only ever http(s), mailto or
 * tel — anything else is its label alone. While a reply is still arriving
 * (`live`), a style whose closing mark has not come yet already applies to the
 * words after it, and a lone mark at the very end is not drawn, so no
 * asterisks flash on screen.
 *
 * protocol.ts `chatMarkdown` / `chatMarkdownText`, ported index for index: it
 * walks UTF-16 units, as JavaScript strings are walked, so a mark is found or
 * not found exactly where the reference finds it — pinned for every SDK by
 * sdk/contract/chat-window.json → `markdown`. Apple's Markdown reader is not
 * used: its rules are not these. Foundation only.
 */

/// One run of words, with its look.
struct ChatSpan: Equatable {
    var text: String
    var bold = false
    var italic = false
    var code = false
    /// The address a tap opens: http(s), mailto or tel only.
    var link: String?
}

/// One block of the agent's words: a paragraph, a bullet, or a numbered item.
struct ChatBlock: Equatable {
    enum Kind: Equatable {
        case paragraph
        case bullet
        case number(Int)
    }

    var kind: Kind
    var spans: [ChatSpan]
}

enum ChatMarkdown {
    private typealias Units = [UInt16]

    private static func u(_ s: String) -> UInt16 { s.utf16.first! }
    private static let newline = u("\n")
    private static let space = u(" ")
    private static let tab = u("\t")
    private static let backslash = u("\\")
    private static let tick = u("`")
    private static let star = u("*")
    private static let underscore = u("_")
    private static let openBracket = u("[")
    private static let closeBracket = u("]")
    private static let openParen = u("(")
    private static let closeParen = u(")")
    private static let hash = u("#")
    private static let dot = u(".")
    private static let dash = u("-")
    private static let bulletMark = u("•")
    private static let escapable = Set("\\`*_[]()#+-.!>~|".utf16)
    private static let urlTail = Set(".,!?:;'\"".utf16)

    /// JavaScript's `\s` for one UTF-16 unit (an absent one counts as a space, as `isSpace(undefined)` does).
    static func isSpace(_ c: UInt16?) -> Bool {
        guard let c = c else { return true }
        switch c {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }

    /// `[\p{L}\p{N}_]` for one UTF-16 unit: a letter, a number or "_" (half a surrogate pair is neither).
    static func isWord(_ c: UInt16?) -> Bool {
        guard let c = c else { return false }
        if c == underscore { return true }
        guard let scalar = Unicode.Scalar(c) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    // MARK: - Blocks

    /// The blocks of an agent's words, formatted. Never throws; plain words are one paragraph.
    static func blocks(_ text: String, live: Bool = false) -> [ChatBlock] {
        var source = normaliseNewlines(Units(text.utf16))
        // A lone mark at the very end of a reply still arriving is the start of something not yet here.
        if live {
            while let last = source.last, last == star || last == underscore || last == tick || last == openBracket {
                source.removeLast()
            }
        }
        var blocks: [ChatBlock] = []
        var para: [Units] = []
        func endPara() {
            if !para.isEmpty {
                let joined = Array(para.joined(separator: [newline]))
                let spans = merge(inline(joined, bold: false, italic: false, live: live))
                if !spans.isEmpty { blocks.append(ChatBlock(kind: .paragraph, spans: spans)) }
            }
            para = []
        }
        for line in source.split(separator: newline, omittingEmptySubsequences: false).map(Units.init) {
            if trim(line).isEmpty {
                endPara()
                continue
            }
            if let words = bullet(line) {
                endPara()
                let spans = merge(inline(trimEnd(words), bold: false, italic: false, live: live))
                if !spans.isEmpty { blocks.append(ChatBlock(kind: .bullet, spans: spans)) }
                continue
            }
            if let item = numbered(line) {
                endPara()
                let spans = merge(inline(trimEnd(item.words), bold: false, italic: false, live: live))
                if !spans.isEmpty { blocks.append(ChatBlock(kind: .number(item.n), spans: spans)) }
                continue
            }
            if let words = heading(line) {
                endPara()
                let spans = merge(inline(trimEnd(stripClosingHashes(words)), bold: true, italic: false, live: live))
                if !spans.isEmpty { blocks.append(ChatBlock(kind: .paragraph, spans: spans)) }
                continue
            }
            para.append(trim(line))
        }
        endPara()
        return blocks
    }

    /// The plain words of formatted blocks — what a long-press copies and a screen reader reads: one line per block.
    static func plainText(_ blocks: [ChatBlock]) -> String {
        blocks.map { b -> String in
            let words = b.spans.map(\.text).joined()
            switch b.kind {
            case .paragraph: return words
            case .bullet: return "• " + words
            case .number(let n): return "\(n). " + words
            }
        }.joined(separator: "\n")
    }

    /// `\r\n` and a lone `\r` are one line break.
    private static func normaliseNewlines(_ s: Units) -> Units {
        let cr = u("\r")
        guard s.contains(cr) else { return s }
        var out: Units = []
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            if s[i] == cr {
                out.append(newline)
                if i + 1 < s.count && s[i + 1] == newline { i += 1 }
            } else {
                out.append(s[i])
            }
            i += 1
        }
        return out
    }

    /// JavaScript's `.` refuses these; a line holding one is no list item and no heading.
    private static func hasLineTerminator(_ s: ArraySlice<UInt16>) -> Bool {
        s.contains { $0 == 0x0A || $0 == 0x0D || $0 == 0x2028 || $0 == 0x2029 }
    }

    /// Up to three leading spaces (more is no marker at all), as ` {0,3}` allows.
    private static func indent(_ line: Units) -> Int? {
        var k = 0
        while k < line.count && line[k] == space { k += 1 }
        return k <= 3 ? k : nil
    }

    /// `[ \t]+(\S.*)$` from `from`: the words, or nil.
    private static func wordsAfterGap(_ line: Units, from: Int) -> Units? {
        var j = from
        guard j < line.count, line[j] == space || line[j] == tab else { return nil }
        while j < line.count && (line[j] == space || line[j] == tab) { j += 1 }
        guard j < line.count, !isSpace(line[j]), !hasLineTerminator(line[j...]) else { return nil }
        return Units(line[j...])
    }

    /// `^ {0,3}[-*•][ \t]+(\S.*)$`
    private static func bullet(_ line: Units) -> Units? {
        guard let k = indent(line), k < line.count else { return nil }
        let c = line[k]
        guard c == dash || c == star || c == bulletMark else { return nil }
        return wordsAfterGap(line, from: k + 1)
    }

    /// `^ {0,3}(\d{1,3})[.)][ \t]+(\S.*)$`
    private static func numbered(_ line: Units) -> (n: Int, words: Units)? {
        guard let k = indent(line) else { return nil }
        var j = k
        while j < line.count, line[j] >= 0x30, line[j] <= 0x39 { j += 1 }
        let digits = j - k
        guard (1...3).contains(digits), j < line.count, line[j] == dot || line[j] == closeParen,
              let words = wordsAfterGap(line, from: j + 1) else { return nil }
        let n = line[k..<j].reduce(0) { $0 * 10 + Int($1 - 0x30) }
        return (n, words)
    }

    /// `^ {0,3}#{1,6}[ \t]+(\S.*)$`
    private static func heading(_ line: Units) -> Units? {
        guard let k = indent(line) else { return nil }
        var j = k
        while j < line.count && line[j] == hash { j += 1 }
        guard (1...6).contains(j - k) else { return nil }
        return wordsAfterGap(line, from: j)
    }

    /// `.replace(/[ \t]+#+[ \t]*$/, "")` — a heading's closing hashes.
    private static func stripClosingHashes(_ s: Units) -> Units {
        var end = s.count
        while end > 0 && (s[end - 1] == space || s[end - 1] == tab) { end -= 1 }
        let hashesEnd = end
        while end > 0 && s[end - 1] == hash { end -= 1 }
        guard end < hashesEnd else { return s }
        let hashesStart = end
        while end > 0 && (s[end - 1] == space || s[end - 1] == tab) { end -= 1 }
        guard end < hashesStart else { return s }
        return Units(s[..<end])
    }

    private static func trim(_ s: Units) -> Units {
        var a = 0, b = s.count
        while a < b && isSpace(s[a]) { a += 1 }
        while b > a && isSpace(s[b - 1]) { b -= 1 }
        return Units(s[a..<b])
    }

    private static func trimEnd(_ s: Units) -> Units {
        var b = s.count
        while b > 0 && isSpace(s[b - 1]) { b -= 1 }
        return Units(s[..<b])
    }

    // MARK: - Inline

    private static func string(_ s: ArraySlice<UInt16>) -> String { String(decoding: s, as: UTF16.self) }

    private static func index(of c: UInt16, in t: Units, from: Int) -> Int {
        guard from < t.count else { return -1 }
        return t[from...].firstIndex(of: c) ?? -1
    }

    private static func hasNewline(_ t: Units, _ from: Int, _ to: Int) -> Bool {
        guard from < to else { return false }
        return t[from..<min(to, t.count)].contains(newline)
    }

    /// `/^https?:\/\//i` on the eight units from `i`.
    private static func startsWithHttp(_ t: Units, _ i: Int) -> Bool {
        let head = string(t[i..<min(i + 8, t.count)]).lowercased()
        return head.hasPrefix("http://") || head.hasPrefix("https://")
    }

    /// `/^https?:\/\/[^/\s]+/i`: the scheme, then at least one character of a host.
    private static func hasHost(_ url: ArraySlice<UInt16>) -> Bool {
        let lower = string(url).lowercased()
        let rest: Substring
        if lower.hasPrefix("https://") { rest = lower.dropFirst(8) } else if lower.hasPrefix("http://") { rest = lower.dropFirst(7) } else { return false }
        guard let first = rest.utf16.first else { return false }
        return first != u("/") && !isSpace(first)
    }

    /// `/^(https?:\/\/|mailto:|tel:)/i`
    private static func linkable(_ url: ArraySlice<UInt16>) -> Bool {
        let lower = string(url).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") || lower.hasPrefix("tel:")
    }

    /// The inline spans of one paragraph's text (protocol.ts `mdInline`).
    private static func inline(_ t: Units, bold: Bool, italic: Bool, live: Bool) -> [ChatSpan] {
        var spans: [ChatSpan] = []
        var buf: Units = []
        func flush() {
            if !buf.isEmpty { spans.append(ChatSpan(text: string(buf[...]), bold: bold, italic: italic)) }
            buf = []
        }
        func at(_ i: Int) -> UInt16? { i >= 0 && i < t.count ? t[i] : nil }
        let n = t.count
        var i = 0
        while i < n {
            let c = t[i]
            // An escaped mark is the mark itself.
            if c == backslash, i + 1 < n, escapable.contains(t[i + 1]) {
                buf.append(t[i + 1])
                i += 2
                continue
            }
            // `code`, on one line, nothing styled inside it.
            if c == tick {
                let j = index(of: tick, in: t, from: i + 1)
                var end = -1
                if j > i + 1 && !hasNewline(t, i + 1, j) {
                    end = j
                } else if live && j < 0 && i + 1 < n && !hasNewline(t, i + 1, n) {
                    end = n
                }
                if end > 0 {
                    flush()
                    spans.append(ChatSpan(text: string(t[(i + 1)..<end]), bold: bold, italic: italic, code: true))
                    i = end == n ? n : end + 1
                    continue
                }
            }
            // [label](address)
            if c == openBracket {
                let close = index(of: closeBracket, in: t, from: i + 1)
                if close > i + 1, close + 1 < n, t[close + 1] == openParen, !hasNewline(t, i + 1, close) {
                    // The address runs to the bracket that closes it — (balanced) brackets inside it are its own.
                    var end = -1
                    var j = close + 2
                    var depth = 0
                    while j < n && !isSpace(t[j]) {
                        if t[j] == openParen {
                            depth += 1
                        } else if t[j] == closeParen {
                            if depth == 0 { end = j; break }
                            depth -= 1
                        }
                        j += 1
                    }
                    let url = end > close + 2 ? t[(close + 2)..<end] : []
                    if !url.isEmpty && !url.contains(where: { isSpace($0) }) {
                        flush()
                        let label = string(t[(i + 1)..<close])
                        spans.append(ChatSpan(text: label, bold: bold, italic: italic, link: linkable(url) ? string(url) : nil))
                        i = end + 1
                        continue
                    }
                }
            }
            // A bare http(s) address.
            if (c == u("h") || c == u("H")) && !isWord(at(i - 1)) && startsWithHttp(t, i) {
                var j = i
                while j < n && !isSpace(t[j]) { j += 1 }
                var url = t[i..<j]
                while let last = url.last, urlTail.contains(last) || (last == closeParen && !url.contains(openParen)) {
                    url = url.dropLast()
                }
                if hasHost(url) {
                    flush()
                    spans.append(ChatSpan(text: string(url), bold: bold, italic: italic, link: string(url)))
                    i += url.count
                    continue
                }
            }
            // **bold** / __bold__
            if (c == star || c == underscore) && at(i + 1) == c {
                // Never inside a word (2**3, snake__case): a mark opens after a non-word and closes before one.
                let opens = !isSpace(at(i + 2)) && at(i + 2) != c && !isWord(at(i - 1))
                if opens {
                    var j = i + 2
                    var found = -1
                    while j < n - 1 {
                        if t[j] == newline { break }
                        if t[j] == c && t[j + 1] == c && !isSpace(at(j - 1)) && !isWord(at(j + 2)) { found = j; break }
                        j += 1
                    }
                    let end = found >= 0 ? found : (live && !hasNewline(t, i + 2, n) ? n : -1)
                    if end > i + 2 {
                        flush()
                        spans += inline(Units(t[(i + 2)..<end]), bold: true, italic: italic, live: live && found < 0)
                        i = end == n ? n : end + 2
                        continue
                    }
                }
                buf += [c, c]
                i += 2
                continue
            }
            // *italic* / _italic_
            if c == star || c == underscore {
                let opens = !isSpace(at(i + 1)) && !isWord(at(i - 1))
                if opens {
                    var j = i + 1
                    var found = -1
                    while j < n {
                        if t[j] == newline { break }
                        if t[j] == c {
                            if at(j + 1) == c { j += 2; continue }
                            if !isSpace(at(j - 1)) && !isWord(at(j + 1)) { found = j; break }
                        }
                        j += 1
                    }
                    let end = found >= 0 ? found : (live && !hasNewline(t, i + 1, n) ? n : -1)
                    if end > i + 1 {
                        flush()
                        spans += inline(Units(t[(i + 1)..<end]), bold: bold, italic: true, live: live && found < 0)
                        i = end == n ? n : end + 1
                        continue
                    }
                }
            }
            buf.append(c)
            i += 1
        }
        flush()
        return spans
    }

    /// Spans side by side with the same look are one span; empty ones go.
    private static func merge(_ spans: [ChatSpan]) -> [ChatSpan] {
        var out: [ChatSpan] = []
        for s in spans where !s.text.isEmpty {
            if var last = out.last, last.bold == s.bold, last.italic == s.italic, last.code == s.code, last.link == s.link {
                last.text += s.text
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }
}

/**
 * A REPLY STILL ARRIVING, REVEALED SMOOTHLY rather than in the bursts the
 * network delivers it in: at least 90 characters a second, faster when behind,
 * never more than about 0.6 s behind what has arrived (protocol.ts
 * `revealLength` / `revealSlice`; vectors chat-window.json → `reveal`). Counts
 * are UTF-16 units, as the reference counts them.
 */
enum ChatReveal {
    static let minCharsPerSecond = 90.0
    static let catchUpMs = 600.0

    /// How much of a streaming reply to show after `elapsedMs` more, from `shown` toward `target` units.
    static func length(shown: Double, target: Double, elapsedMs: Double) -> Int {
        let goal = max(0, target.rounded(.down))
        let now = max(0, min(goal, shown.rounded(.down)))
        guard now < goal, elapsedMs > 0 else { return Int(now) }
        let cps = max(minCharsPerSecond, (goal - now) * 1000 / catchUpMs)
        return Int(min(goal, now + max(1, (cps * elapsedMs / 1000).rounded(.down))))
    }

    /// The first `length` UTF-16 units of `text`, never splitting a surrogate pair (an emoji drawn half).
    static func slice(_ text: String, _ length: Int) -> String {
        let units = Array(text.utf16)
        var n = max(0, min(units.count, length))
        if n > 0 && n < units.count, (0xD800...0xDBFF).contains(units[n - 1]) { n += 1 }
        return String(decoding: units[..<n], as: UTF16.self)
    }

    /// A text's length as the reveal counts it.
    static func count(_ text: String) -> Int { text.utf16.count }
}
