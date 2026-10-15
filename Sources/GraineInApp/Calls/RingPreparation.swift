import Foundation

/**
 * A CALL GRAINE RANG, PREPARED WHILE IT RINGS (WEBRTC-CALLS §2).
 *
 * The push woke the app; the person has not answered yet. Everything a WebRTC
 * call needs before the INVITE — the call session, the registration, the peer
 * and its candidates — is done now, so answering costs one INVITE. The answer
 * takes the prepared leg (by the call's id); a decline, a missed or expired
 * ring, or anything else that ends the call hangs it up — no INVITE was ever
 * sent, so nobody was called. A leg nobody takes is closed after `keepSeconds`
 * whatever happens.
 */
final class RingPreparation {
    static let shared = RingPreparation()

    /// Longer than any ring (60 s at most) — a backstop, not the rule.
    static let keepSeconds: TimeInterval = 90

    private let lock = NSLock()
    private var legs: [String: GraineRtcCall] = [:]
    private var watching = Set<ObjectIdentifier>()

    /// Keep `leg` for the answer to `callId`. One per call: an older one is hung up.
    func put(_ callId: String, _ leg: GraineRtcCall) {
        lock.lock()
        let older = legs[callId]
        legs[callId] = leg
        lock.unlock()
        older?.hangUp()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keepSeconds) { [weak self, weak leg] in
            guard let self = self, let leg = leg else { return }
            self.discard(callId, only: leg)
        }
    }

    /// The answer takes it: the caller owns it from here.
    func take(_ callId: String?) -> GraineRtcCall? {
        guard let id = callId, !id.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return legs.removeValue(forKey: id)
    }

    /// Hang it up and forget it — or only `leg`, when another took its place.
    func discard(_ callId: String?, only leg: GraineRtcCall? = nil) {
        guard let id = callId else { return }
        lock.lock()
        let held = legs[id]
        if let held = held, leg == nil || held === leg {
            legs.removeValue(forKey: id)
        }
        lock.unlock()
        if let held = held, leg == nil || held === leg { held.hangUp() }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return legs.count
    }

    #if os(iOS)
    /// Hears the calls' states, so a ring that ends unanswered lets its leg go at once. Main thread.
    func watch(_ calls: GraineCalls) {
        let id = ObjectIdentifier(calls)
        lock.lock()
        let first = watching.insert(id).inserted
        lock.unlock()
        if first { calls.addListener(listener) }
    }

    private lazy var listener = RingPreparationListener(self)
    #endif
}

#if os(iOS)
/// The calls' listener: any end of a call closes what was prepared for it.
private final class RingPreparationListener: GraineCallsListener {
    private weak var store: RingPreparation?

    init(_ store: RingPreparation) {
        self.store = store
    }

    func onCallState(_ state: GraineCallState, callId: String?) {
        switch state {
        case .ended, .idle:
            store?.discard(callId)
        case .ringing, .connecting, .active:
            break
        }
    }
}

extension GraineCalls {
    /**
     * A ring arrived: prepare its WebRTC leg now, when this call will try
     * WebRTC (the module is in the app, the app did not ask for the WebSocket,
     * the dashboard has not turned WebRTC off). With exactly what answering
     * would send: the ringing agent's key, the call's variables and who the
     * customer is, with the call's id. Main thread.
     */
    func prepareRing(_ call: GraineIncomingCall, agent: GraineInApp) {
        guard config.callTransport != .websocket, let module = GraineRtcRegistry.module, module.isSupported else { return }
        let requested = config.callTransport
        let whoCalled = CallEngine.whoCalled(hosted: call.hosted)
        let own = GraineCalls.maskedVariables(call.variables)
        let setup = CallEngine.Setup(
            publishableKey: agent.config.publishableKey,
            baseUrl: agent.config.baseUrl,
            variables: CallEngine.variables(sdk: agent.currentVariables(), whoCalled: whoCalled, reason: call.reason, own: own),
            contextFrame: { nil },
            session: CallEngine.sessionLoader(agent),
            runAction: { _, _, answer in answer(.refused("")) },
            callVariables: CallEngine.variables(sdk: [:], whoCalled: whoCalled, reason: call.reason, own: own),
            identity: agent.identityFields(callId: call.callId)
        )
        let debug = agent.config.debug
        RingPreparation.shared.watch(self)
        setup.session { [weak self] session in
            DispatchQueue.main.async {
                guard let self = self, let session = session, self.callId == call.callId, self.state == .ringing,
                      CallTransportChoice.decide(requested: requested, dashboard: session.calls?.audioTransport, rtcAvailable: true) == .webrtc
                else { return }
                let leg = module.makeCall(CallConversation.rtcRequest(setup: setup, session: session, debug: debug))
                RingPreparation.shared.put(call.callId, leg)
                leg.prepare()
                if debug { GraineLog.trace("call: preparing WebRTC while it rings") }
            }
        }
    }

    /// What the call ran on (CallConversation's report), for the call screen and the log. Main thread.
    func transportDecided(_ report: CallTransportReport, callId id: String?) {
        guard id == callId else { return }
        if transport != report.transport { transport = report.transport }
        if transportFallbackReason != report.reason { transportFallbackReason = report.reason }
        if let reason = report.reason, callAgent?.config.debug == true {
            GraineLog.trace("call transport: \(report.transport.rawValue) (asked for \(report.requested?.rawValue ?? "-"), because \(reason))")
        }
    }
}
#endif
