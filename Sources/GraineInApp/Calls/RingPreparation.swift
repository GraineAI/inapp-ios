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
 *
 * A leg minted with something other than what the answer would mint — the
 * customer became known or changed while it rang (an app its push woke before
 * the session said who they are), or the variables did — is not taken: it is
 * hung up and the call minted again, as Android does, so the conversation runs
 * as who the customer is now — at the gateway, with the grant asked for the
 * ring under them (GraineInApp.warmCalls).
 */
final class RingPreparation {
    static let shared = RingPreparation()

    /// Longer than any ring (60 s at most) — a backstop, not the rule.
    static let keepSeconds: TimeInterval = 90

    /// A leg, and what it was minted with: its request's mint body for an empty session id.
    private struct Prepared {
        let leg: GraineRtcCall
        let mint: Data?
    }

    private let lock = NSLock()
    private var legs: [String: Prepared] = [:]
    private var watching = Set<ObjectIdentifier>()

    /// Keep `leg` for the answer to `callId`, with what it was minted with. One per call: an older one is hung up.
    func put(_ callId: String, _ leg: GraineRtcCall, mint: Data? = nil) {
        lock.lock()
        let older = legs[callId]
        // Compared without what renews on its own (the app's pass, the user's): RtcMintBody.stable.
        legs[callId] = Prepared(leg: leg, mint: mint.map(RtcMintBody.stable))
        lock.unlock()
        older?.leg.hangUp()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keepSeconds) { [weak self, weak leg] in
            guard let self = self, let leg = leg else { return }
            self.discard(callId, only: leg)
        }
    }

    /// The answer takes it — the caller owns it from here — when it was minted with `mint` (nil: whatever it was minted with).
    func take(_ callId: String?, mint: Data? = nil) -> GraineRtcCall? {
        guard let id = callId, !id.isEmpty else { return nil }
        lock.lock()
        let held = legs.removeValue(forKey: id)
        lock.unlock()
        guard let prepared = held else { return nil }
        if let wanted = mint.map(RtcMintBody.stable), let had = prepared.mint, wanted != had {
            prepared.leg.hangUp()
            return nil
        }
        return prepared.leg
    }

    /// Hang it up and forget it — or only `leg`, when another took its place.
    func discard(_ callId: String?, only leg: GraineRtcCall? = nil) {
        guard let id = callId else { return }
        lock.lock()
        let held = legs[id]
        let matches = held.map { leg == nil || $0.leg === leg } ?? false
        if matches { legs.removeValue(forKey: id) }
        lock.unlock()
        if matches { held?.leg.hangUp() }
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
            identity: agent.identityFields(callId: call.callId),
            security: agent.security,
            tokens: agent.clientTokens
        )
        let debug = agent.config.debug
        RingPreparation.shared.watch(self)
        setup.session { [weak self] session in
            DispatchQueue.main.async {
                guard let self = self, let session = session, self.callId == call.callId, self.state == .ringing,
                      CallTransportChoice.decide(requested: requested, dashboard: session.calls?.audioTransport, rtcAvailable: true) == .webrtc
                else { return }
                // A call that rang: its mint's answer brings a grant for exactly this call — kept, so a mint made for it
                // once it is answered (a leg made then, a redial) goes to the telephony gateway; only an answer without
                // one has it asked for on its own. One request to the web route per ring.
                var request = CallConversation.rtcRequest(setup: setup, session: session, debug: debug)
                request.rang = true
                let leg = module.makeCall(request)
                RingPreparation.shared.put(call.callId, leg, mint: request.mintBody(""))
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
