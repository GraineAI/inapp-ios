import Foundation
import Testing
@testable import GraineInApp

/*
 * THE FACE STAGE — the rule that decides what the stage over the agent's face
 * shows, against contract/avatar-stage.json (generated from avatarStage() in
 * sdk/inapp/protocol.ts): every case and every clock reading, exactly.
 */

@Suite struct AvatarStageContractTests {
    private func captions(_ raw: Any?) -> [GraineStageCaption] {
        ((raw as? [[String: Any]]) ?? []).map {
            GraineStageCaption(
                who: ($0["who"] as? String) == "agent" ? .agent : .customer,
                text: $0["text"] as? String ?? "",
                final: $0["final"] as? Bool ?? true
            )
        }
    }

    private func ms(_ raw: Any?) -> Double? { (raw as? NSNumber)?.doubleValue }

    private func input(_ raw: [String: Any]) throws -> AvatarStage.Input {
        let n = try #require(raw["native"] as? [String: Any])
        let v = try #require(raw["voice"] as? [String: Any])
        return AvatarStage.Input(
            native: AvatarStage.Side(
                word: n["phase"] as? String ?? "", muted: n["muted"] as? Bool ?? false, speaker: n["speaker"] as? Bool ?? true,
                startedAt: ms(n["startedAt"]), captions: captions(n["captions"])
            ),
            voice: AvatarStage.Side(
                word: v["status"] as? String ?? "", muted: v["muted"] as? Bool ?? false, speaker: v["speaker"] as? Bool ?? true,
                startedAt: ms(v["startedAt"]), captions: captions(v["captions"]), captionsOn: v["captionsOn"] as? Bool ?? true
            ),
            chat: raw["chat"] as? Bool ?? false
        )
    }

    @Test func everyCaseDecidesAsTheTypeScriptDoes() throws {
        let c = try ContractFile.load("avatar-stage.json")
        let cases = try #require(c["cases"] as? [[String: Any]])
        #expect(cases.count >= 20)
        for v in cases {
            let name = v["name"] as? String ?? "?"
            let got = AvatarStage.decide(try input(try #require(v["input"] as? [String: Any])))
            let want = try #require(v["stage"] as? [String: Any])
            #expect(got.call.rawValue == want["call"] as? String, "\(name): call")
            #expect(got.phase.rawValue == want["phase"] as? String, "\(name): phase")
            #expect(got.status == want["status"] as? String, "\(name): status")
            #expect(got.live == want["live"] as? Bool, "\(name): live")
            #expect(got.startedAt == ms(want["startedAt"]), "\(name): startedAt")
            if let wc = want["caption"] as? [String: Any] {
                #expect(got.caption?.who == ((wc["who"] as? String) == "agent" ? .agent : .customer), "\(name): caption who")
                #expect(got.caption?.text == wc["text"] as? String, "\(name): caption text")
                #expect(got.caption?.final == wc["final"] as? Bool, "\(name): caption final")
            } else {
                #expect(got.caption == nil, "\(name): no caption")
            }
            #expect(got.muted == want["muted"] as? Bool, "\(name): muted")
            #expect(got.speaker == want["speaker"] as? Bool, "\(name): speaker")
            #expect(got.controls.map(\.rawValue) == want["controls"] as? [String], "\(name): controls")
            #expect(got.enabled.map(\.rawValue) == want["enabled"] as? [String], "\(name): enabled")
            #expect(got.endLabel == want["endLabel"] as? String, "\(name): endLabel")
        }
    }

    @Test func theWordsAndNamesAreTheContracts() throws {
        let c = try ContractFile.load("avatar-stage.json")
        #expect(GraineStagePhase.allCases.map(\.rawValue) == c["phases"] as? [String])
        #expect(GraineStageControl.allCases.map(\.rawValue) == c["controls"] as? [String])
        let status = try #require(c["status"] as? [String: String])
        for phase in GraineStagePhase.allCases {
            #expect(AvatarStage.status[phase] == status[phase.rawValue], "\(phase)")
        }
    }

    @Test func theClockReadsAsTheTypeScriptDoes() throws {
        let c = try ContractFile.load("avatar-stage.json")
        let readings = try #require(c["clock"] as? [[String: Any]])
        #expect(readings.count >= 10)
        for r in readings {
            let ms = try #require(ms(r["ms"]))
            #expect(AvatarStage.clock(elapsedMs: ms) == r["text"] as? String, "\(ms)")
        }
        #expect(AvatarStage.clock(elapsedMs: .nan) == "0:00")
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(GraineStageState.clock(from: start, to: start.addingTimeInterval(42)) == "0:42")
    }
}
