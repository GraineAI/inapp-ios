import Combine
import CoreGraphics
import CoreText
import Foundation

/**
 * THE DESIGN'S TYPEFACES, FETCHED AND REGISTERED BY THE SDK ITSELF.
 *
 * A brand picks a typeface in the dashboard; until now a phone drew it only
 * if the app happened to bundle that exact family, which in practice was
 * never. Now the SDK does it: GraineFonts (Core/Fonts.swift) decides which
 * faces the design draws with, and this fetches each one from Graine's
 * `/api/embed/font`, keeps the file on disk, registers it with CoreText and
 * tells every view to redraw. The app names no font.
 *
 * - Off the main thread: the download, the disk and the registration.
 * - Never fetched twice: a face is asked for once per process, and a file on
 *   disk (Caches, keyed by its URL) is registered without the network — the
 *   URL changes when the file does (`v=`), so a kept file is never stale.
 * - Silent on failure: until a face arrives, and if it never does, views draw
 *   the system font at the weight. Nothing throws and the customer sees no
 *   warning; a failed face is tried again on the next launch.
 *
 * Not UIKit: CoreText registers fonts on the Mac as well, so `swift test`
 * drives this whole path with a local fetch and a temporary directory.
 */
final class GraineFontStore: ObservableObject {

    /// Delivers a face's bytes, or nil for any failure. Called off the main thread; may answer from any thread.
    typealias Fetch = (URL, @escaping (Data?) -> Void) -> Void

    /**
     * `family|weight` → the PostScript name of the face registered for it.
     * Main thread. A view reads it through `postScriptName` and redraws when it
     * grows — a face that lands mid-call changes the bar in place.
     */
    @Published private(set) var faces: [String: String] = [:]

    private let directory: URL?
    private let fetch: Fetch
    private let work = DispatchQueue(label: "ai.graine.inapp.fonts", qos: .utility)
    private let lock = NSLock()
    /// URLs asked for in this process — landed, on their way, or failed.
    private var asked: Set<String> = []

    /// - Parameters:
    ///   - directory: where files are kept between launches; nil keeps nothing (every launch fetches).
    ///   - fetch: how bytes arrive; Graine over URLSession unless a test says otherwise.
    init(directory: URL? = GraineFontStore.defaultDirectory(), fetch: @escaping Fetch = GraineFontStore.download) {
        self.directory = directory
        self.fetch = fetch
    }

    /**
     * Load every face not asked for yet in this process. `done` runs on the
     * main thread once each of them has landed or failed — for tests; the views
     * hear it through `faces`.
     */
    func load(_ wanted: [GraineFontFace], done: (() -> Void)? = nil) {
        let group = DispatchGroup()
        for face in wanted {
            lock.lock()
            let fresh = asked.insert(face.url).inserted
            lock.unlock()
            guard fresh else { continue }
            group.enter()
            work.async { self.resolve(face) { group.leave() } }
        }
        group.notify(queue: .main) { done?() }
    }

    /// The registered face for `family` drawn at `weight` (its nearest weight), or nil for the system font. Main thread.
    func postScriptName(family: String, weight: Int) -> String? {
        GraineFonts.loadedKey(family: family, weight: weight).flatMap { faces[$0] }
    }

    // MARK: - One face

    /// From disk when this phone already has it, else from Graine. `finished` runs once, after `faces` is updated.
    private func resolve(_ face: GraineFontFace, finished: @escaping () -> Void) {
        let file = cacheFile(for: face)
        if let file = file, let kept = try? Data(contentsOf: file) {
            if let name = GraineFontStore.register(kept) {
                land(face, name, finished)
                return
            }
            // A damaged file must not stand between the customer and the typeface for ever.
            try? FileManager.default.removeItem(at: file)
        }
        guard let url = URL(string: face.url) else {
            finished()
            return
        }
        fetch(url) { data in
            self.work.async {
                // A 404 page, a proxy's error or half a file is not a font: nothing is kept or registered.
                guard let data = data, let name = GraineFontStore.register(data) else {
                    finished()
                    return
                }
                if let file = file { self.keep(data, at: file) }
                self.land(face, name, finished)
            }
        }
    }

    private func land(_ face: GraineFontFace, _ postScriptName: String, _ finished: @escaping () -> Void) {
        let key = GraineFonts.key(family: face.family, weight: face.weight)
        DispatchQueue.main.async {
            if self.faces[key] != postScriptName { self.faces[key] = postScriptName }
            finished()
        }
    }

    // MARK: - Registration

    /**
     * Registers a TTF with CoreText for this process and returns its PostScript
     * name — the name UIFont asks for — or nil when the bytes are not a font.
     *
     * A face already registered under that name (the app bundles the same
     * file, or it is a system face) is drawable by the name all the same, so
     * that refusal counts as success.
     */
    static func register(_ data: Data) -> String? {
        guard !data.isEmpty,
              let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider),
              let name = font.postScriptName as String?, !name.isEmpty else { return nil }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterGraphicsFont(font, &error) { return name }
        let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
        let drawable = [CTFontManagerError.alreadyRegistered.rawValue, CTFontManagerError.duplicatedName.rawValue]
        return drawable.contains(code) ? name : nil
    }

    // MARK: - The files kept between launches

    static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ai.graine.inapp", isDirectory: true)
            .appendingPathComponent("fonts", isDirectory: true)
    }

    /**
     * One file per URL: the face's name for whoever looks in the folder, and a
     * stable hash of the whole URL (origin and version included), so a new
     * version or a self-hosted origin is a new file rather than a stale one.
     */
    func cacheFile(for face: GraineFontFace) -> URL? {
        directory?.appendingPathComponent(face.name + "-" + GraineFontStore.fnv1a(face.url) + ".ttf", isDirectory: false)
    }

    private func keep(_ data: Data, at file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            // Not kept: the face still draws this launch, and the next one fetches it again.
        }
    }

    /// FNV-1a, 64-bit, as hex: stable across launches, unlike Swift's seeded Hasher.
    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    // MARK: - The network

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    /// The default fetch: one GET, and anything but a 200 with a body is a failure.
    static func download(_ url: URL, _ done: @escaping (Data?) -> Void) {
        let task = session.dataTask(with: URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20)) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done(error == nil && status == 200 ? data : nil)
        }
        task.resume()
    }
}
