import Foundation

/*
 * ONE CALL AT A TIME, AND WHAT BECAME OF IT — the native call's state machine,
 * pure, so every outcome a client's server is told about is proven on a Mac.
 *
 *   idle → ringing (incoming only) → connecting → active → ended(reason) → idle
 *
 * Outcomes are what the app's listener hears, for its server: `answered`,
 * `declined`, `missed` (no answer within the ring timeout, or a push that
 * arrived while a call was live), `ended(local | remote | failed)` and
 * `failed(error)` (it never connected). Every one carries the call id.
 */

/// Who rang whom.
public enum GraineCallDirection: String, Sendable {
    /// The agent rang the customer (a VoIP push).
    case incoming
    /// The customer called the agent (`startCall`).
    case outgoing
}

/// Why a call is over.
public enum GraineCallEndReason: String, Sendable {
    /// The customer hung up (or the app called `end()`).
    case local
    /// The agent hung up.
    case remote
    /// The line could not be kept, or never came up.
    case failed
    /// The customer declined the ring.
    case declined
    /// Nobody answered within the ring timeout.
    case missed
}

/// Where the call is.
public enum GraineCallState: Equatable, Sendable {
    case idle
    /// An agent's call is ringing on the device.
    case ringing
    /// Answered or placed; the conversation is being opened.
    case connecting
    /// Talking.
    case active
    /// Over. Becomes `idle` once reported.
    case ended(GraineCallEndReason)

    /// A call is being placed, rung or held: no other may start.
    public var isLive: Bool {
        switch self {
        case .ringing, .connecting, .active: return true
        case .idle, .ended: return false
        }
    }
}

/// What became of a call — for the app's server.
public enum GraineCallOutcome: Equatable, Sendable {
    /// The customer answered the agent's call.
    case answered
    /// The customer declined it.
    case declined
    /// Nobody answered within the ring timeout — or it arrived while another call was live.
    case missed
    /// A call that connected is over: `.local`, `.remote` or `.failed`.
    case ended(GraineCallEndReason)
    /// It never connected, and why.
    case failed(String)
}

public extension GraineCallOutcome {
    /// One word for your server — `answered`, `declined`, `missed`, `ended` or `failed` — the same words Android reports.
    var wire: String {
        switch self {
        case .answered: return "answered"
        case .declined: return "declined"
        case .missed: return "missed"
        case .ended: return "ended"
        case .failed: return "failed"
        }
    }

    /// Who ended a call that connected (`.ended`): `local`, `remote` or `failed`. Nil otherwise.
    var endReason: GraineCallEndReason? {
        if case .ended(let reason) = self { return reason }
        return nil
    }

    /// Why a call never connected (`.failed`). Nil otherwise.
    var error: String? {
        if case .failed(let why) = self { return why }
        return nil
    }
}

/// The machine. Each event returns what changed; an event that does not apply changes nothing.
struct CallMachine {
    struct Call: Equatable {
        let id: String
        let direction: GraineCallDirection
    }

    enum Event: Equatable {
        /// A ring arrived (an agent's call).
        case incoming(id: String)
        /// The customer placed a call.
        case outgoing(id: String)
        case answer
        case decline
        case ringTimeout
        /// The conversation is open.
        case connected
        /// The customer (or the app) hung up.
        case hangUp
        /// The agent hung up.
        case remoteEnded
        /// A connected call's line dropped.
        case dropped
        /// Could not be placed or connected.
        case failed(String)
        /// The system reset every call.
        case reset
        /// The end has been reported: back to idle.
        case settle
    }

    struct Transition: Equatable {
        /// False when the event did not apply (a second call while one is live, an answer with nothing ringing).
        let accepted: Bool
        let state: GraineCallState
        /// The call the outcomes are about (the refused one, for a refused ring).
        let callId: String?
        let outcomes: [GraineCallOutcome]
    }

    private(set) var state: GraineCallState = .idle
    private(set) var call: Call?

    mutating func handle(_ event: Event) -> Transition {
        switch (event, state) {
        case (.incoming(let id), let s) where !s.isLive:
            call = Call(id: id, direction: .incoming)
            return move(.ringing)
        case (.incoming(let id), _):
            // One call at a time: the newcomer is missed, the live call untouched.
            return Transition(accepted: false, state: state, callId: id, outcomes: [.missed])

        case (.outgoing(let id), let s) where !s.isLive:
            call = Call(id: id, direction: .outgoing)
            return move(.connecting)
        case (.outgoing, _):
            return refused()

        case (.answer, .ringing):
            return move(.connecting, [.answered])
        case (.decline, .ringing), (.hangUp, .ringing):
            return move(.ended(.declined), [.declined])
        case (.ringTimeout, .ringing):
            return move(.ended(.missed), [.missed])

        case (.connected, .connecting):
            return move(.active)

        case (.hangUp, .connecting), (.hangUp, .active):
            return move(.ended(.local), [.ended(.local)])
        case (.remoteEnded, .active):
            return move(.ended(.remote), [.ended(.remote)])
        case (.dropped, .active):
            return move(.ended(.failed), [.ended(.failed)])
        case (.remoteEnded, .connecting), (.dropped, .connecting):
            return move(.ended(.failed), [.failed("The line closed before the call connected.")])
        case (.failed(let error), .ringing), (.failed(let error), .connecting):
            return move(.ended(.failed), [.failed(error)])
        case (.failed, .active):
            return move(.ended(.failed), [.ended(.failed)])

        case (.reset, .ringing):
            return move(.ended(.missed), [.missed])
        case (.reset, .connecting):
            return move(.ended(.failed), [.failed("The system ended the call.")])
        case (.reset, .active):
            return move(.ended(.failed), [.ended(.failed)])

        case (.settle, .ended):
            let id = call?.id
            call = nil
            state = .idle
            return Transition(accepted: true, state: .idle, callId: id, outcomes: [])

        default:
            return refused()
        }
    }

    private mutating func move(_ next: GraineCallState, _ outcomes: [GraineCallOutcome] = []) -> Transition {
        state = next
        return Transition(accepted: true, state: next, callId: call?.id, outcomes: outcomes)
    }

    private func refused() -> Transition {
        Transition(accepted: false, state: state, callId: call?.id, outcomes: [])
    }
}

// MARK: - The push

/// An agent's call, as the client's server pushed it.
public struct GraineIncomingCall: Equatable, Sendable {
    /// The server's id for this call. Every outcome carries it back.
    public let callId: String
    /// Why the agent is calling — the prompt's `call_reason`.
    public let reason: String?
    /// The name to ring with, over `GraineCallsConfig.displayName`.
    public let callerName: String?
    /// Extra prompt variables for this call.
    public let variables: [String: String]

    public init(callId: String, reason: String? = nil, callerName: String? = nil, variables: [String: String] = [:]) {
        self.callId = callId
        self.reason = reason
        self.callerName = callerName
        self.variables = variables
    }
}

/**
 * THE PUSH PAYLOAD a client's server sends (keys are strings, as on Android):
 *
 *     { "type": "agent_call", "call_id": "c_123", "reason": "payment_due",
 *       "caller_name": "Acme", "variables": "{\"name\":\"Asha\"}" }
 *
 * `type` and `call_id` are required. `variables` is a JSON object as a string
 * (an object is taken too); an unreadable one is ignored, not fatal — the call
 * still rings, without them. The keys may also sit under `data`.
 */
enum CallPush {
    enum Problem: Error, Equatable {
        /// Not an agent call at all (`type` is missing or something else).
        case notAnAgentCall
        /// An agent call with no `call_id`.
        case missingCallId
    }

    static let type = "agent_call"

    static func parse(_ payload: [AnyHashable: Any]) -> Result<GraineIncomingCall, Problem> {
        var fields = strings(payload)
        if fields["type"] == nil, let nested = payload["data"] as? [AnyHashable: Any] {
            fields = strings(nested)
        }
        guard fields["type"]?.value == type else { return .failure(.notAnAgentCall) }
        guard let id = nonEmpty(fields["call_id"]?.text) else { return .failure(.missingCallId) }
        return .success(GraineIncomingCall(
            callId: id,
            reason: nonEmpty(fields["reason"]?.text),
            callerName: nonEmpty(fields["caller_name"]?.text),
            variables: variables(fields["variables"]?.raw)
        ))
    }

    /// The call id of a push that is not usable, when it has one — so even a refused ring can be reported.
    static func callId(_ payload: [AnyHashable: Any]) -> String? {
        var fields = strings(payload)
        if fields["call_id"] == nil, let nested = payload["data"] as? [AnyHashable: Any] {
            fields = strings(nested)
        }
        return nonEmpty(fields["call_id"]?.text)
    }

    private struct Field {
        let raw: Any
        /// The value as text, when it is a scalar.
        var text: String? { JSON.text(raw) }
        /// The value, trimmed and lower-cased: for `type`.
        var value: String? { text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    private static func strings(_ payload: [AnyHashable: Any]) -> [String: Field] {
        var out: [String: Field] = [:]
        for (key, value) in payload {
            guard let name = key.base as? String, let v = JSON.unwrap(value), !(v is NSNull) else { continue }
            out[name] = Field(raw: v)
        }
        return out
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// A JSON object string (or an object) → prompt variables. Anything else → none.
    private static func variables(_ raw: Any?) -> [String: String] {
        var object: [String: Any]?
        if let s = raw as? String {
            object = JSON.object(from: s)
        } else if let dict = raw as? [String: Any] {
            object = dict
        } else if let dict = raw as? [AnyHashable: Any] {
            object = JSON.normalize(dict) as? [String: Any]
        }
        guard let values = object else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in values where !key.isEmpty {
            if let text = CallWire.scalarText(value) { out[key] = text }
        }
        return out
    }
}

/**
 * WHAT TO DO WITH A PUSH — decided before anything else happens, and always
 * starting with CallKit: iOS stops delivering VoIP pushes to an app that does
 * not report every one of them as a call, so a malformed push and a push that
 * arrives mid-call are reported too, then ended at once.
 */
enum PushIntake {
    enum Step: Equatable {
        /// Report it to CallKit as a new incoming call. Always first.
        case report(callerName: String)
        /// Then let it ring: the call is the machine's.
        case ring(GraineIncomingCall)
        /// Then end it at once.
        case endAtOnce(Ending)
        /// Tell the app what became of it.
        case outcome(callId: String, GraineCallOutcome)
    }

    enum Ending: Equatable {
        /// Not a usable push.
        case failed
        /// A call is already live (or it is that call again).
        case unanswered
    }

    static func plan(
        _ payload: [AnyHashable: Any],
        displayName: String,
        liveCallId: String?
    ) -> [Step] {
        switch CallPush.parse(payload) {
        case .failure:
            var steps: [Step] = [.report(callerName: displayName), .endAtOnce(.failed)]
            if let id = CallPush.callId(payload), id != liveCallId {
                steps.append(.outcome(callId: id, .failed("The push was not an agent call this SDK can ring.")))
            }
            return steps
        case .success(let call):
            let name = call.callerName ?? displayName
            guard let live = liveCallId else { return [.report(callerName: name), .ring(call)] }
            // The same call pushed twice: one ring is enough, and it is not missed.
            if live == call.callId { return [.report(callerName: name), .endAtOnce(.unanswered)] }
            return [.report(callerName: name), .endAtOnce(.unanswered), .outcome(callId: call.callId, .missed)]
        }
    }
}
