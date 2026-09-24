import Foundation
import Testing
@testable import GraineInApp

/**
 * THE SHARED CONTRACT, generated from the React Native SDK (sdk/contract).
 *
 * Every answer in fixtures.json was produced by the React Native SDK's own
 * built code; this SDK must reproduce each one exactly. When a rule changes
 * there, the fixtures are regenerated and this goes red until iOS matches:
 *
 *   cd sdk/inapp && npm run build && node ../contract/generate.mjs
 *
 * A missing fixtures file FAILS — it never skips.
 */
@Suite struct ContractTests {

    private func fixtures() throws -> [String: Any] {
        try ContractFile.load("fixtures.json")
    }

    @Test func masksExactlyWhatTheReactNativeSdkMasks() throws {
        let cases = try #require(try fixtures()["mask"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for c in cases {
            let input = try #require(c["input"] as? String)
            let output = try #require(c["output"] as? String)
            #expect(GraineMasking.mask(input) == output, "input: \(input)")
        }
    }

    @Test func meansTheSameByWeakConnection() throws {
        let cases = try #require(try fixtures()["quality"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for c in cases {
            let sample = c["sample"] as? [String: Any]
            let expected = try #require(c["quality"] as? String)
            #expect(GraineConnectionQuality.classify(sample: sample).rawValue == expected, "sample: \(String(describing: sample))")
        }
    }

    @Test func buildsTheSameEngineUrl() throws {
        let cases = try #require(try fixtures()["engineUrl"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for c in cases {
            let input = try #require(c["input"] as? [String: Any])
            let expected = try #require(c["url"] as? String)
            let url = GraineProtocol.engineUrl(
                baseUrl: try #require(input["baseUrl"] as? String),
                voiceAgentId: try #require(input["voiceAgentId"] as? String),
                transport: GraineTransport.from(try #require(input["transport"] as? String)),
                cacheKey: try #require(input["cacheKey"] as? String),
                idle: try #require(input["idle"] as? Bool),
                publishableKey: try #require(input["publishableKey"] as? String),
                accent: input["accent"] as? String
            )
            #expect(url == expected)
        }
    }
}

/// Finds a file under sdk/contract by walking up from this source file, so it works from any checkout location.
enum ContractFile {
    struct NotFound: Error, CustomStringConvertible {
        let name: String
        let searchedFrom: String
        var description: String {
            "sdk/contract/\(name) was not found walking up from \(searchedFrom). Regenerate it with sdk/contract/generate*.mjs."
        }
    }

    static func load(_ name: String, from here: String = #filePath) throws -> [String: Any] {
        let data = try Data(contentsOf: try locate(name, from: here))
        let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try #require(parsed as? [String: Any], "\(name) is not a JSON object")
    }

    static func text(_ name: String, from here: String = #filePath) throws -> String {
        try String(contentsOf: try locate(name, from: here), encoding: .utf8)
    }

    /// contract/ in the standalone repository, sdk/contract/ in the monorepo — whichever is above us.
    static func locate(_ name: String, from here: String) throws -> URL {
        let start = URL(fileURLWithPath: here).deletingLastPathComponent()
        var dir = start
        for _ in 0..<12 {
            for candidate in ["contract/\(name)", "sdk/contract/\(name)"] {
                let file = dir.appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: file.path) { return file }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw NotFound(name: name, searchedFrom: start.path)
    }
}

@Suite struct SocketTraceContractTests {
    /// The debug tracer every SDK injects is one script, extracted from the Android SDK into
    /// contract/socket-trace.js. Compared without the surrounding newlines: a Swift multiline
    /// literal drops them, and to a JavaScript engine they are the same script.
    @Test func theTracerIsTheSharedOneVerbatim() throws {
        let shared = try ContractFile.text("socket-trace.js")
        #expect(EngineScripts.socketTrace.trimmingCharacters(in: .whitespacesAndNewlines)
                == shared.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
