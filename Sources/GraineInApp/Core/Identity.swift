import CryptoKit
import Foundation
import Security

/*
 * WHO THE CUSTOMER IS, FOR MEMORY — the identity channel (contract §1).
 *
 * `identify(traits)` has always fed the prompt's variables, masked on the
 * device. The agent's Identity setting (the session's `identity.field`) names
 * ONE of those traits — `user_id` by default, or `email`, `phone`, a custom
 * trait — and its value is ALSO kept raw, for one purpose: the identity
 * channel on the requests that start a conversation (`identity: {value}`).
 * Graine derives a one-way key from it at the first hop and never stores the
 * raw value. It never enters variables, context frames or logs.
 *
 * With it go `installId` (a UUID this SDK keeps in the Keychain for the life
 * of the install), the customer's memory choice, and the device's time zone.
 * Pure: Foundation, Security and CryptoKit only, so a Mac proves it.
 */

/// The agent's Identity setting, from the session: which trait names the customer, and how many devices they may use.
public struct GraineIdentitySettings: Equatable, Sendable {
    /// `user_id` (the default), `email`, `phone`, or a custom trait such as `patient_id`.
    public let field: String
    /// How many devices one customer's memory may be used from (1–5, default 2).
    public let devicesPerUser: Int

    public init(field: String = "user_id", devicesPerUser: Int = 2) {
        self.field = IdentityRules.normaliseField(field) ?? "user_id"
        self.devicesPerUser = min(5, max(1, devicesPerUser))
    }

    /// What applies when the session says nothing (an older server): `user_id`, two devices.
    public static let standard = GraineIdentitySettings()

    /// The session's `identity`, or nil when it is absent or not an object. A bad field is the default.
    static func parse(_ raw: Any?) -> GraineIdentitySettings? {
        guard let o = JSON.unwrap(raw) as? [String: Any] else { return nil }
        let field = IdentityRules.normaliseField(o["field"]) ?? "user_id"
        var devices = 2
        if let v = JSON.unwrap(o["devicesPerUser"]), let n = JSON.number(v), n.doubleValue.isFinite {
            devices = Int(n.doubleValue.rounded())
        }
        return GraineIdentitySettings(field: field, devicesPerUser: devices)
    }
}

/**
 * WHICH VALUES ARE AN IDENTITY — the reference rules' `normalise_field` and
 * `normalise_value` (contract §1.4), held to contract/identity-vectors.json.
 *
 * The SDK never derives the key; the server does. It uses these only to decide
 * whether there IS an identity: a placeholder ("null", "guest", a masked
 * "[EMAIL]"), a boolean, an object, a fraction — or a value the server would
 * refuse anyway (an email with no domain, a 5-digit phone) — is no identity,
 * and the conversation is anonymous rather than keyed on a value that names
 * nobody. What is sent is the value as the app gave it; the server normalises.
 */
enum IdentityRules {
    /// What the server trims (Python's `str.strip()`, contract §1.4) — not Foundation's whitespace: it strips
    /// U+001C–U+001F, which `.whitespacesAndNewlines` keeps, and keeps U+FEFF. Pinned by identity-vectors.json.
    static let serverWhitespace: CharacterSet = {
        var set = CharacterSet(charactersIn: "\t\n\u{0B}\u{0C}\r \u{85}\u{A0}\u{1680}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}")
        set.insert(charactersIn: Unicode.Scalar(UInt32(0x1C))!...Unicode.Scalar(UInt32(0x1F))!)
        set.insert(charactersIn: Unicode.Scalar(UInt32(0x2000))!...Unicode.Scalar(UInt32(0x200A))!)
        return set
    }()

    /// Python's `str.lower()` (contract §1.4): the full mapping of U+0130 ("İ" → "i̇") and the context-sensitive
    /// final sigma ("ΟΔΟΣ" → "οδος"), which Swift's `lowercased()` does not apply.
    static func serverLowercased(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, c) in scalars.enumerated() {
            if c.value == 0x0130 {
                out.append("i"); out.append(Unicode.Scalar(UInt32(0x0307))!)
                continue
            }
            if c.value == 0x03A3 {
                var j = i - 1
                while j >= 0, scalars[j].properties.isCaseIgnorable { j -= 1 }
                let before = j >= 0 && scalars[j].properties.isCased
                var k = i + 1
                while k < scalars.count, scalars[k].properties.isCaseIgnorable { k += 1 }
                let after = k < scalars.count && scalars[k].properties.isCased
                out.append(Unicode.Scalar(UInt32(before && !after ? 0x03C2 : 0x03C3))!)
                continue
            }
            out.append(contentsOf: String(c).lowercased().unicodeScalars)
        }
        return String(out)
    }

    static let placeholders: Set<String> = [
        "", "null", "undefined", "none", "nil", "nan", "unknown", "anonymous", "anon", "guest", "0", "-", "n/a",
        "na", "test", "[phone]", "[email]", "[pan]", "[aadhaar]", "[card]",
    ]

    /// trim, lower-case, `^[a-z][a-z0-9_]{0,39}$`; nil otherwise.
    static func normaliseField(_ raw: Any?) -> String? {
        guard let s = JSON.unwrap(raw) as? String else { return nil }
        let f = s.trimmingCharacters(in: serverWhitespace).lowercased()
        guard let first = f.unicodeScalars.first, f.unicodeScalars.count <= 40,
              ("a"..."z").contains(first),
              f.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }) else { return nil }
        return f
    }

    /**
     * The value as the app handed it, as text: a string as it is, a whole
     * number in decimals. Nil for null, a boolean, an object, a list or a
     * fraction. (JavaScript has no integers, so a number that is whole — 4242,
     * or 4242.0 from a bridge — counts as one; 4242.5 does not.)
     */
    static func rawText(_ raw: Any?) -> String? {
        guard let v = JSON.unwrap(raw), !(v is NSNull) else { return nil }
        if let s = v as? String { return s }
        if JSON.bool(v) != nil { return nil }
        guard let n = JSON.number(v) else { return nil }
        if integerTypes.contains(String(cString: n.objCType)) { return n.stringValue }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(.towardZero), abs(d) < 9.0e15 else { return nil }
        return String(Int64(d))
    }

    private static let integerTypes: Set<String> = ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"]

    /// The reference `normalise_value`: the value the server keys on, or nil when there is none.
    static func normalisedValue(field: String, value raw: Any?) -> String? {
        guard let text = rawText(raw) else { return nil }
        let v = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: serverWhitespace)
        if placeholders.contains(v.lowercased()) { return nil }
        switch field {
        case "email":
            let lower = serverLowercased(v)
            return lower.unicodeScalars.count <= 254 && looksLikeEmail(lower) ? lower : nil
        case "phone":
            // ASCII digits only, as the server counts them: other scripts' digits do not make a phone number.
            let digits = String(String.UnicodeScalarView(v.unicodeScalars.filter { $0.value >= 0x30 && $0.value <= 0x39 }))
            let count = digits.unicodeScalars.count
            guard (8...15).contains(count) else { return nil }
            return String(String.UnicodeScalarView(digits.unicodeScalars.suffix(10)))
        default:
            return v.unicodeScalars.count <= 256 ? v : nil
        }
    }

    /// `^[^@\s]+@[^@\s]+\.[^@\s]+$`, as Python reads it: one "@" with something before it, and a dot inside what follows.
    private static func looksLikeEmail(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        if scalars.contains(where: { $0.properties.isWhitespace }) { return false }
        let ats = scalars.indices.filter { scalars[$0] == "@" }
        guard ats.count == 1, let at = ats.first, at > 0 else { return false }
        let domain = Array(scalars[(at + 1)...])
        return domain.indices.contains { domain[$0] == "." && $0 > 0 && $0 < domain.count - 1 }
    }

    /// The identity value to send for `traits` under `field`: the trait's raw text, when it is an identity at all.
    static func value(in traits: [String: Any?]?, field: String) -> String? {
        guard let traits = traits else { return nil }
        // An exact key first; else the same name in another case — `userId` is not `user_id`, but `User_ID` is.
        let raw: Any?? = traits[field] ?? traits.first { $0.key.lowercased() == field }?.value
        guard let found = raw, normalisedValue(field: field, value: found) != nil else { return nil }
        return rawText(found)
    }
}

// MARK: - The install

/// Where the install id lives. The Keychain on a device; memory in tests.
protocol InstallIdStore: AnyObject {
    func read() -> String?
    @discardableResult func write(_ id: String) -> Bool
}

/**
 * THE INSTALL ID, in the Keychain: available after the first unlock (a VoIP
 * push can wake the app before anyone opens it), this device only (never
 * restored onto another phone from a backup), and kept when the app is
 * deleted and installed again — so a reinstall is the same device, and keeps
 * its place among a customer's devices.
 */
final class KeychainInstallIdStore: InstallIdStore {
    private let service: String
    private let account = "install-id"

    init(service: String = "ai.graine.inapp") {
        self.service = service
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ id: String) -> Bool {
        let data = Data(id.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// An install id that lives as long as the process: for tests.
final class MemoryInstallIdStore: InstallIdStore {
    var value: String?
    private(set) var writes = 0
    var failWrites = false

    init(_ value: String? = nil) {
        self.value = value
    }

    func read() -> String? { value }

    func write(_ id: String) -> Bool {
        writes += 1
        if failWrites { return false }
        value = id
        return true
    }
}

enum InstallId {
    /// A UUID, lower case — what the server accepts (`^[0-9a-f-]{16,64}$`).
    static func isValid(_ s: String?) -> Bool {
        guard let s = s, (16...64).contains(s.count) else { return false }
        return s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) || $0 == "-" }
    }

    /**
     * The install's id: the one kept, or a new UUIDv4, kept. If the Keychain
     * will not keep it (locked, or refusing), the new one serves this launch
     * and the next launch tries again — never a second id written over a
     * first that could not be read for a moment.
     */
    static func resolve(_ store: InstallIdStore) -> (id: String, kept: Bool) {
        if let kept = store.read()?.lowercased(), isValid(kept) { return (kept, true) }
        let fresh = UUID().uuidString.lowercased()
        return (fresh, store.write(fresh))
    }
}

// MARK: - The memory choice

/**
 * THE CUSTOMER'S MEMORY CHOICE, kept per (install, identity) so an app need not
 * repeat it on every launch. Keyed by a one-way hash of the field and the
 * normalised value — the raw value is never written to disk — and capped, the
 * oldest choices going first.
 */
final class MemoryChoices {
    static let key = "ai.graine.inapp.memory"
    static let cap = 32

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func hash(field: String, value: String) -> String {
        let normalised = IdentityRules.normalisedValue(field: field, value: value) ?? value
        let digest = SHA256.hash(data: Data(("graine:memory:v1\n" + field + "\n" + normalised).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func choice(field: String, value: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        let all = defaults.dictionary(forKey: MemoryChoices.key) ?? [:]
        guard let entry = all[MemoryChoices.hash(field: field, value: value)] as? [String: Any] else { return nil }
        return JSON.unwrap(entry["on"]).flatMap { JSON.bool($0) }
    }

    func remember(_ on: Bool, field: String, value: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var all = defaults.dictionary(forKey: MemoryChoices.key) ?? [:]
        all[MemoryChoices.hash(field: field, value: value)] = ["on": on, "at": now.timeIntervalSince1970]
        if all.count > MemoryChoices.cap {
            let oldest = all.sorted { at($0.value) < at($1.value) }.prefix(all.count - MemoryChoices.cap)
            for (k, _) in oldest { all.removeValue(forKey: k) }
        }
        defaults.set(all, forKey: MemoryChoices.key)
    }

    private func at(_ entry: Any) -> Double {
        ((entry as? [String: Any])?["at"] as? NSNumber)?.doubleValue ?? 0
    }
}

// MARK: - The current identity

/**
 * WHO IS SIGNED IN, AS THE IDENTITY CHANNEL SEES IT. The traits are held raw,
 * in memory only, until the session says which one names the customer (a
 * ticket is never minted before the session anyway); then the value is read
 * from them. A value that changes — a sign-out, or another customer signing in
 * on the same phone — leaves the previous one to be signed out on the server,
 * so the device stops being theirs. Thread-safe.
 */
final class IdentityState {
    /// What a request carries.
    struct Snapshot: Equatable {
        var value: String?
        var memory: Bool
    }

    private let lock = NSLock()
    private let choices: MemoryChoices?
    private var traits: [String: Any?]?
    private var field: String?
    /// The app's latest explicit choice, before the field is known to file it under.
    private var unfiledMemory: Bool?
    private var memoryOverride: Bool?
    private var resolved: String?
    /// Values that stopped being the customer's and still need their sign-out sent.
    private var signedOut: [String] = []

    init(choices: MemoryChoices?) {
        self.choices = choices
    }

    /// The session said which trait names the customer.
    func setField(_ next: String) {
        lock.lock()
        defer { lock.unlock() }
        field = next
        resolveLocked()
        if let memory = unfiledMemory, let value = resolved {
            choices?.remember(memory, field: next, value: value)
        }
        unfiledMemory = nil
    }

    var knownField: String? {
        lock.lock()
        defer { lock.unlock() }
        return field
    }

    /// `identify(traits, memory:)`. nil traits sign out.
    func identify(_ next: [String: Any?]?, memory: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        traits = next
        memoryOverride = nil
        resolveLocked()
        if let memory = memory { fileMemoryLocked(memory) }
    }

    /// `setMemory(enabled)`: the current customer's choice, kept for them.
    func setMemory(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        fileMemoryLocked(enabled)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(value: resolved, memory: memoryLocked())
    }

    /// The values to sign out, once each.
    func takeSignOuts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let out = signedOut
        signedOut = []
        return out
    }

    private func fileMemoryLocked(_ memory: Bool) {
        memoryOverride = memory
        if let f = field, let value = resolved {
            choices?.remember(memory, field: f, value: value)
        } else if field == nil {
            unfiledMemory = memory
        }
    }

    private func memoryLocked() -> Bool {
        if let explicit = memoryOverride { return explicit }
        if let f = field, let value = resolved, let kept = choices?.choice(field: f, value: value) { return kept }
        return true
    }

    private func resolveLocked() {
        guard let f = field else { return }
        let next = IdentityRules.value(in: traits, field: f)
        if let previous = resolved, previous != next, !signedOut.contains(previous) {
            signedOut.append(previous)
        }
        if let next = next { signedOut.removeAll { $0 == next } }
        if resolved != next {
            // Another customer: their own kept choice applies, not the last customer's.
            memoryOverride = nil
        }
        resolved = next
    }
}

// MARK: - On the wire

/// The identity fields every request in contract §1.3 carries.
enum IdentityWire {
    struct Fields: Equatable {
        var value: String?
        var installId: String?
        var memory: Bool
        var timezone: String
        var callId: String?
    }

    /// The device's IANA zone: `Asia/Kolkata`.
    static func deviceTimezone() -> String {
        TimeZone.current.identifier
    }

    /// `identity: {value}` (only with one), `installId`, `memory`, `timezone`, `callId` (only with one).
    static func pairs(_ f: Fields) -> [(String, WireJSON)] {
        var out: [(String, WireJSON)] = []
        if let value = f.value { out.append(("identity", .object([("value", .string(value))]))) }
        if let install = f.installId { out.append(("installId", .string(install))) }
        out.append(("memory", .bool(f.memory)))
        if !f.timezone.isEmpty { out.append(("timezone", .string(f.timezone))) }
        if let call = f.callId, !call.isEmpty { out.append(("callId", .string(call))) }
        return out
    }
}
