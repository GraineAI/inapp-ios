#if os(iOS)
import SwiftUI

/**
 * A CALL SCREEN for while your app is in the foreground: the agent's name,
 * where the call is, the line being said, and mute / speaker / end (answer
 * and decline while it rings). The system's own call screen covers the lock
 * screen and the background; present this over your UI when you want the
 * call inside the app too.
 *
 *     .fullScreenCover(isPresented: .constant(calls.state.isLive)) { GraineCallView() }
 */
public struct GraineCallView: View {
    @ObservedObject private var calls: GraineCalls

    /// The calls to draw; `GraineInApp.shared.calls` when nil.
    public init(calls: GraineCalls? = nil) {
        self.calls = calls ?? GraineInApp.shared.calls
    }

    public var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.08, blue: 0.10).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer().frame(height: 72)
                avatar
                Text(calls.callerName.isEmpty ? " " : calls.callerName)
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.top, 20)
                status
                    .font(.callout)
                    .foregroundColor(Color.white.opacity(0.7))
                    .padding(.top, 6)
                Spacer()
                if let line = calls.caption, !line.text.isEmpty {
                    Text(line.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.body)
                        .foregroundColor(Color.white.opacity(line.role == .agent ? 0.95 : 0.75))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 28)
                        .transition(.opacity)
                }
                Spacer()
                controls.padding(.bottom, 56)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 112, height: 112)
                .scaleEffect(calls.agentSpeaking ? 1.08 : 1)
                .animation(.easeInOut(duration: 0.35), value: calls.agentSpeaking)
            Text(String(calls.callerName.prefix(1)).uppercased())
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(.white)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var status: some View {
        switch calls.state {
        case .idle:
            Text(" ")
        case .ringing:
            Text("Incoming call")
        case .connecting:
            Text(calls.direction == .incoming ? "Connecting…" : "Calling…")
        case .active:
            if let since = calls.connectedAt {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(GraineCallView.elapsed(from: since, to: context.date)
                         + (calls.agentSpeaking ? " · Speaking" : ""))
                        .monospacedDigit()
                }
            } else {
                Text("Connected")
            }
        case .ended(let reason):
            Text(GraineCallView.endedText(reason))
        }
    }

    @ViewBuilder private var controls: some View {
        if calls.state == .ringing {
            HStack(spacing: 72) {
                CallButton(symbol: "phone.down.fill", label: "Decline", tint: .red, filled: true) { calls.end() }
                CallButton(symbol: "phone.fill", label: "Answer", tint: .green, filled: true) { calls.answer() }
            }
        } else {
            HStack(spacing: 40) {
                CallButton(symbol: calls.muted ? "mic.slash.fill" : "mic.fill", label: calls.muted ? "Unmute" : "Mute",
                           tint: .white, filled: calls.muted) { calls.setMuted(!calls.muted) }
                CallButton(symbol: "speaker.wave.2.fill", label: "Speaker",
                           tint: .white, filled: calls.speakerOn) { calls.setSpeaker(!calls.speakerOn) }
                CallButton(symbol: "phone.down.fill", label: "End", tint: .red, filled: true) { calls.end() }
                    .disabled(!calls.state.isLive)
            }
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func endedText(_ reason: GraineCallEndReason) -> String {
        switch reason {
        case .local, .remote: return "Call ended"
        case .failed: return "Call failed"
        case .declined: return "Declined"
        case .missed: return "Missed call"
        }
    }
}

/// One round control: a symbol over its label.
private struct CallButton: View {
    let symbol: String
    let label: String
    let tint: Color
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(filled ? tint : Color.white.opacity(0.14))
                        .frame(width: 68, height: 68)
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(filled ? (tint == .white ? .black : .white) : .white)
                }
                Text(label)
                    .font(.footnote)
                    .foregroundColor(Color.white.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
#endif
