import Foundation

/*
 * THE DESIGN'S TYPEFACES — which faces a design draws with, and where each
 * one is served. contract/DESIGN.md "Fonts".
 *
 * A brand picks a typeface in the dashboard and expects the phone to draw it,
 * with nothing in the app naming a font. So the SDK decides everything here:
 * the body family at `weights.body` and `weights.strong`, the heading family at
 * `weights.title` and `weights.strong`, for the light and the dark token set
 * alike (a device can switch mid-session, and a face fetched late is a
 * flash of the system font). Each at the nearest weight the family actually
 * has, from Graine's own origin — never a third party the app did not already
 * talk to.
 *
 * Pure: Foundation only, so `swift test` pins every answer against
 * contract/design.json (`cases[].fontFaces`, `fontWeights`,
 * `fontAssetVersion`). GraineFonts.swift fetches, keeps and registers what
 * this decides.
 */

/// One face of one family: what the SDK downloads, registers and draws with.
struct GraineFontFace: Equatable, Hashable {
    /// The curated family, spelled as the dashboard spells it: "DM Sans".
    let family: String
    /// The weight the family has nearest the one the design asked for.
    let weight: Int
    /**
     * `Graine-<family, letters and digits only>-<weight>`: the contract's name
     * for the face, and the key other SDKs register it under. iOS cannot choose
     * the name a font registers under — that is the PostScript name inside the
     * file — so here it names the cached file and identifies the face; the
     * registered PostScript name is what UIFont is asked for.
     */
    let name: String
    /// `<origin>/api/embed/font?f=<family>&w=<weight>&v=<version>`.
    let url: String
}

enum GraineFonts {

    /// Bumped by the server when a file behind /api/embed/font changes, so no year-long cache keeps the old one.
    static let assetVersion = 1

    /**
     * Every family the dashboard offers, with the weights it has files for
     * (contract/design.json → `fontWeights`, which the tests compare against).
     * A family missing here has no files: it is drawn in the system font.
     */
    static let weights: [String: [Int]] = [
        "Inter": [100, 200, 300, 400, 500, 600, 700, 800, 900],
        "Roboto": [100, 200, 300, 400, 500, 600, 700, 800, 900],
        "Geist": [100, 200, 300, 400, 500, 600, 700, 800, 900],
        "IBM Plex Sans": [100, 200, 300, 400, 500, 600, 700],
        "IBM Plex Sans Devanagari": [100, 200, 300, 400, 500, 600, 700],
        "DM Sans": [100, 200, 300, 400, 500, 600, 700, 800, 900],
        "Noto Sans": [100, 200, 300, 400, 500, 600, 700, 800, 900],
        "Noto Sans Devanagari": [100, 200, 300, 400, 500, 600, 700, 800, 900],
        "Noto Sans Tamil": [100, 200, 300, 400, 500, 600, 700, 800, 900],
        "Mukta": [200, 300, 400, 500, 600, 700, 800],
        "Hind": [300, 400, 500, 600, 700],
        "Anek Devanagari": [100, 200, 300, 400, 500, 600, 700, 800],
        "Poppins": [100, 200, 300, 400, 500, 600, 700, 800, 900],
        "Baloo 2": [400, 500, 600, 700, 800],
        "Nunito": [200, 300, 400, 500, 600, 700, 800, 900],
        "Atkinson Hyperlegible Next": [200, 300, 400, 500, 600, 700, 800],
        "Source Serif 4": [200, 300, 400, 500, 600, 700, 800, 900],
        "Newsreader": [200, 300, 400, 500, 600, 700, 800],
        "Fraunces": [100, 200, 300, 400, 500, 600, 700, 800, 900],
        "Playfair Display": [400, 500, 600, 700, 800, 900],
        "Tiro Devanagari Hindi": [400],
        "Noto Serif Devanagari": [100, 200, 300, 400, 500, 600, 700, 800, 900],
        "Martel": [200, 300, 400, 600, 700, 800, 900],
        "JetBrains Mono": [100, 200, 300, 400, 500, 600, 700, 800],
    ]

    /// How a loaded face is looked up: `family|weight`, the family as `weights` spells it.
    static func key(family: String, weight: Int) -> String {
        family + "|" + String(weight)
    }

    /// The weight a family has nearest the one asked for; on a tie, the heavier. Nil when it has none.
    static func nearestWeight(_ available: [Int], to want: Int) -> Int? {
        guard var best = available.first else { return nil }
        for w in available {
            let d = abs(w - want)
            let bestD = abs(best - want)
            if d < bestD || (d == bestD && w > best) { best = w }
        }
        return best
    }

    /// Where Graine serves one face. The family is encoded as JavaScript's encodeURIComponent would: "DM%20Sans".
    static func url(origin: String?, family: String, weight: Int) -> String {
        let trimmed = (origin ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = GraineProtocol.trimTrailingSlashes(trimmed.isEmpty ? Appearance.defaultOrigin : trimmed)
        return base + "/api/embed/font?f=" + GraineProtocol.encode(family)
            + "&w=" + String(weight) + "&v=" + String(assetVersion)
    }

    /// `Graine-<family with only letters and digits>-<weight>`.
    static func registryName(family: String, weight: Int) -> String {
        let letters = family.unicodeScalars.filter { s in
            (s >= "A" && s <= "Z") || (s >= "a" && s <= "z") || (s >= "0" && s <= "9")
        }
        return "Graine-" + String(letters) + "-" + String(weight)
    }

    /// The family as the curated list spells it — matched as written, then ignoring case — or nil when it is not offered.
    static func canonicalFamily(_ family: String) -> String? {
        let want = family.trimmingCharacters(in: .whitespacesAndNewlines)
        if weights[want] != nil { return want }
        return weights.keys.first { $0.caseInsensitiveCompare(want) == .orderedSame }
    }

    /**
     * The face to load for `family` drawn at `weight` — or nil for the system
     * font, and for a family this build has no files for (a newer dashboard's):
     * that one is drawn in the system font, silently, as DESIGN.md promises.
     */
    static func face(family: String, weight: Int, origin: String?) -> GraineFontFace? {
        guard let (canonical, w) = resolve(family: family, weight: weight) else { return nil }
        return GraineFontFace(
            family: canonical,
            weight: w,
            name: registryName(family: canonical, weight: w),
            url: url(origin: origin, family: canonical, weight: w)
        )
    }

    /// The `key` a loaded face for `family` at `weight` is kept under — what a view looks up on every draw, without building a URL.
    static func loadedKey(family: String, weight: Int) -> String? {
        resolve(family: family, weight: weight).map { key(family: $0.family, weight: $0.weight) }
    }

    private static func resolve(family: String, weight: Int) -> (family: String, weight: Int)? {
        guard !DesignRules.isSystemFamily(family),
              let canonical = canonicalFamily(family),
              let available = weights[canonical],
              let w = nearestWeight(available, to: weight) else { return nil }
        return (canonical, w)
    }

    /// The faces one token set draws with: body at body and strong, heading at title and strong. Each once.
    static func faces(for tokens: GraineThemeTokens, origin: String?) -> [GraineFontFace] {
        let f = tokens.font
        let wanted = [
            (f.body, f.weights.body), (f.body, f.weights.strong),
            (f.heading, f.weights.title), (f.heading, f.weights.strong),
        ]
        var out: [GraineFontFace] = []
        for (family, weight) in wanted {
            guard let face = face(family: family, weight: weight, origin: origin), !out.contains(face) else { continue }
            out.append(face)
        }
        return out
    }

    /// Every face a design can draw with, in either scheme — each once, light's first.
    static func faces(for design: GraineDesign, origin: String?) -> [GraineFontFace] {
        var out = faces(for: design.light, origin: origin)
        for face in faces(for: design.dark, origin: origin) where !out.contains(face) {
            out.append(face)
        }
        return out
    }
}
