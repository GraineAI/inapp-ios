#if os(iOS)
import SwiftUI
import UIKit

/*
 * THE BOOKING SHEET — "Call me at…" with no screen of the app's own
 * (BOOKING-SHEET.md §2–3). The customer picks a day (chips, today to the
 * agent's furthest), a time (the system's time wheel, every 5 minutes, only
 * times the agent's rules allow), and may say what it is about; "Book call"
 * books it with `scheduleCall`, and the sheet says when the agent will ring.
 * A refusal stays in the sheet as one line under the button. Drawn from the
 * design's tokens, as the chat window is. The rules and the words are in
 * Core/Booking.swift.
 *
 *     let call = await GraineInApp.shared.presentBooking()               // UIKit or SwiftUI, from anywhere
 *     .graineBookingSheet(isPresented: $booking) { call in … }           // SwiftUI
 *     GraineBookingView { call in dismiss() }                             // your own presentation
 */

// MARK: - Presenting it

extension GraineInApp {
    /**
     * Show the booking sheet over whatever is on screen (the key window's top
     * view controller): a sheet on an iPhone, a centred panel on an iPad.
     * Returns the call once the sheet closes — nil when the customer closed it
     * without booking. `reason` fills "What's it about?", which the customer
     * may change; it is kept with the call for the agent, never put in a push.
     *
     * Check `bookingAvailable` before offering it: an agent that cannot be
     * booked now opens a sheet that says why and books nothing.
     */
    @MainActor
    public func presentBooking(reason: String? = nil) async -> GraineScheduledCall? {
        await withCheckedContinuation { (continuation: CheckedContinuation<GraineScheduledCall?, Never>) in
            presentBooking(reason: reason) { continuation.resume(returning: $0) }
        }
    }

    /// `presentBooking(reason:)` on a callback, called once (the Objective-C facade's). Main thread.
    func presentBooking(reason: String?, done: @escaping (GraineScheduledCall?) -> Void) {
        guard let top = GraineBookingViewController.topViewController() else {
            GraineLog.warning("The booking sheet has nothing to present over: no window is on screen yet.")
            done(nil)
            return
        }
        if top is GraineBookingViewController {
            // Already open: one booking at a time.
            done(nil)
            return
        }
        if !bookingAvailable {
            GraineLog.warning("The booking sheet opened while this agent cannot be booked; it says why. Check bookingAvailable before offering it.")
        }
        top.present(GraineBookingViewController(graine: self, reason: reason, done: done), animated: true)
    }
}

/**
 * The booking sheet for a UIKit app that presents it itself: a sheet on an
 * iPhone, a centred panel on an iPad. `done` hears the booked call when it
 * closes, or nil. `GraineInApp.presentBooking()` presents one for you.
 */
public final class GraineBookingViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private let graine: GraineInApp?
    private let reason: String?
    private let done: ((GraineScheduledCall?) -> Void)?
    /// The call booked in this sheet, handed back when it closes.
    private var booked: GraineScheduledCall?
    private var finished = false

    /// - Parameters:
    ///   - graine: defaults to the instance `GraineInApp.configure` made.
    ///   - reason: what "What's it about?" starts with.
    ///   - done: the booked call once the sheet has closed; nil when nothing was booked.
    public init(graine: GraineInApp? = nil, reason: String? = nil, done: ((GraineScheduledCall?) -> Void)? = nil) {
        self.graine = graine
        self.reason = reason
        self.done = done
        super.init(nibName: nil, bundle: nil)
        // The app's window, not the screen: an iPad app in a narrow split gets the phone's sheet.
        let window = GraineVoice.keyWindow()?.bounds.size ?? UIScreen.main.bounds.size
        if Double(min(window.width, window.height)) >= ChatWindowLayout.tabletMinSide {
            // An iPad: a centred panel, the chat panel's width.
            modalPresentationStyle = .formSheet
            preferredContentSize = CGSize(width: ChatWindowLayout.panelWidth, height: 640)
        } else {
            modalPresentationStyle = .pageSheet
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GraineBookingViewController is made in code: GraineBookingViewController(graine:reason:done:).")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        presentationController?.delegate = self
        view.backgroundColor = .clear
        let sheet = GraineBookingView(
            graine: graine, reason: reason,
            onBooked: { [weak self] call in self?.booked = call },
            onBusy: { [weak self] busy in self?.isModalInPresentation = busy },
            onClose: { [weak self] call in self?.close(call) }
        )
        let controller = UIHostingController(rootView: sheet)
        controller.view.backgroundColor = .clear
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
    }

    /// Closed by the sheet's own controls (Done, the close button).
    private func close(_ call: GraineScheduledCall?) {
        if let call = call { booked = call }
        dismiss(animated: true) { [weak self] in self?.finish() }
    }

    /// Swiped down.
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        done?(booked)
    }

    /// What is on screen now: the key window's root, and whatever it presents.
    static func topViewController() -> UIViewController? {
        var top = GraineVoice.keyWindow()?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

public extension View {
    /**
     * The booking sheet, while `isPresented`: `onBooked` hears the call the
     * moment it is booked; the sheet closes itself on Done or its close button.
     *
     *     Button("Call me back") { booking = true }
     *         .disabled(!GraineInApp.shared.bookingAvailable)
     *         .graineBookingSheet(isPresented: $booking) { call in upcoming.append(call) }
     */
    func graineBookingSheet(
        isPresented: Binding<Bool>,
        graine: GraineInApp? = nil,
        reason: String? = nil,
        onBooked: ((GraineScheduledCall) -> Void)? = nil
    ) -> some View {
        sheet(isPresented: isPresented) {
            GraineBookingView(graine: graine, reason: reason, onBooked: onBooked) { _ in isPresented.wrappedValue = false }
        }
    }
}

// MARK: - The sheet

/**
 * THE BOOKING SHEET'S CONTENT, for an app that presents it its own way:
 * the title, the day chips, the time wheel, the device's time zone, "What's
 * it about? (optional)", and "Book call" — then "Booked — … will call you on
 * …" with Done. `onBooked` hears the call when it is booked; `onClose` when
 * the customer is done with the sheet (Done, or the close button), with the
 * booked call or nil. Fills the space it is given, in the design's surface.
 */
public struct GraineBookingView: View {
    private let graine: GraineInApp?
    private let reason: String?
    private let onBooked: ((GraineScheduledCall) -> Void)?
    private let onBusy: ((Bool) -> Void)?
    private let onClose: (GraineScheduledCall?) -> Void

    /// - Parameters:
    ///   - graine: defaults to the instance `GraineInApp.configure` made. Nothing draws before that.
    ///   - reason: what "What's it about?" starts with.
    ///   - onBooked: the call, the moment it is booked.
    ///   - onClose: the customer closed the sheet: the booked call, or nil.
    public init(
        graine: GraineInApp? = nil,
        reason: String? = nil,
        onBooked: ((GraineScheduledCall) -> Void)? = nil,
        onClose: @escaping (GraineScheduledCall?) -> Void
    ) {
        self.init(graine: graine, reason: reason, onBooked: onBooked, onBusy: nil, onClose: onClose)
    }

    init(
        graine: GraineInApp?,
        reason: String?,
        onBooked: ((GraineScheduledCall) -> Void)?,
        onBusy: ((Bool) -> Void)?,
        onClose: @escaping (GraineScheduledCall?) -> Void
    ) {
        self.graine = graine
        self.reason = reason
        self.onBooked = onBooked
        self.onBusy = onBusy
        self.onClose = onClose
    }

    public var body: some View {
        if let graine = graine ?? GraineInApp.current {
            GraineBookingSheet(
                graine: graine, chat: graine.chat, fonts: graine.fonts, reason: reason,
                onBooked: onBooked, onBusy: onBusy, onClose: onClose
            )
        }
    }
}

struct GraineBookingSheet: View {
    let graine: GraineInApp
    /// Watched so the sheet hears who is signed in change (GraineChat redraws on it).
    @ObservedObject var chat: GraineChat
    @ObservedObject var fonts: GraineFontStore
    let onBooked: ((GraineScheduledCall) -> Void)?
    let onBusy: ((Bool) -> Void)?
    let onClose: (GraineScheduledCall?) -> Void

    @StateObject private var model: GraineAppearanceModel
    @State private var flow: BookingFlow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        graine: GraineInApp, chat: GraineChat, fonts: GraineFontStore, reason: String?,
        onBooked: ((GraineScheduledCall) -> Void)?, onBusy: ((Bool) -> Void)?, onClose: @escaping (GraineScheduledCall?) -> Void
    ) {
        self.graine = graine
        _chat = ObservedObject(wrappedValue: chat)
        _fonts = ObservedObject(wrappedValue: fonts)
        self.onBooked = onBooked
        self.onBusy = onBusy
        self.onClose = onClose
        _model = StateObject(wrappedValue: GraineAppearanceModel(graine: graine))
        _flow = State(initialValue: BookingFlow(rules: graine.schedulingRules, now: Date(), reason: reason))
    }

    private var dash: GraineNativeAppearance {
        Appearance.resolve(model.appearance, accent: Appearance.defaultAccent, heading: "Assistant", origin: graine.config.baseUrl)
    }

    /// The brand's tokens, as the chat window draws them; without a design, the classic look around the accent.
    private var tokens: GraineThemeTokens {
        model.design?.tokens(deviceDark: colorScheme == .dark) ?? DesignTokens.classic(dark: colorScheme == .dark, accent: dash.accent)
    }

    private var callName: String {
        Booking.callName(graine.sessionOrCached?.calls?.callName, title: tokens.chat?.title, heading: dash.heading)
    }

    var body: some View {
        let t = tokens
        let type = GraineType(font: t.font, names: graine.config.fonts, faces: fonts.faces)
        let blocked = graine.bookingBlocked
        VStack(alignment: .leading, spacing: 0) {
            header(t, type)
            Rectangle().fill(Color.graineHex(t.colors.border)).frame(height: CGFloat(max(1, t.shape.borderWidth)))
            if let call = flow.booked {
                confirmation(t, type, call)
            } else {
                form(t, type, blocked: blocked)
            }
        }
        .background(Color.graineHex(t.colors.surface).ignoresSafeArea())
        .environment(\.colorScheme, t.scheme == "dark" ? .dark : .light)
        .interactiveDismissDisabled(flow.isBooking)
        .onReceive(model.$design) { _ in
            // The session arrived after the sheet opened: its rules are the ones to offer.
            let rules = graine.schedulingRules
            if rules != flow.rules { flow.refresh(now: Date(), rules: rules) }
        }
    }

    // MARK: Header

    private func header(_ t: GraineThemeTokens, _ type: GraineType) -> some View {
        let titleSize = min(t.font.scale.title, 20)
        let muted = Color.graineHex(t.colors.textMuted)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Booking.title)
                    .font(type.heading(titleSize, t.font.weights.title))
                    .tracking(type.titleTracking(titleSize))
                    .foregroundColor(.graineHex(t.colors.text))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(Booking.subtitle(callName: callName))
                    .font(type.body(t.font.scale.caption, t.font.weights.body))
                    .tracking(type.bodyTracking(t.font.scale.caption))
                    .foregroundColor(muted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: { onClose(flow.booked) }) {
                GraineIconView(name: .close, style: t.icons.style, stroke: t.icons.stroke, color: muted, size: 20)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(flow.isBooking)
            .accessibilityLabel("Close")
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 12)
    }

    // MARK: Picking

    private func form(_ t: GraineThemeTokens, _ type: GraineType, blocked: String?) -> some View {
        let c = t.colors
        let dayIndex = flow.dayIndex
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                label(Booking.dayLabel, t, type)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(flow.days.enumerated()), id: \.offset) { index, day in
                                chip(day.label, selected: index == dayIndex, t, type) { flow.pickDay(index) }
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .onAppear { proxy.scrollTo(dayIndex, anchor: .center) }
                }
                .padding(.horizontal, -20)
                label(Booking.timeLabel, t, type).padding(.top, 8)
                if let day = flow.day {
                    GraineTimeWheel(
                        date: Binding(get: { flow.at }, set: { flow.pickTime($0) }),
                        minimum: day.first, maximum: day.last,
                        dark: t.scheme == "dark", tint: UIColor(Color.graineHex(c.accent))
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .disabled(flow.isBooking)
                    Text(Booking.zoneLine(flow.at))
                        .font(type.body(t.font.scale.caption, t.font.weights.body))
                        .foregroundColor(.graineHex(c.textMuted))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityLabel("Time zone \(Booking.zoneLine(flow.at))")
                }
                label(Booking.reasonLabel, t, type).padding(.top, 8)
                reasonField(t, type)
                bookButton(t, type, enabled: blocked == nil && flow.day != nil)
                    .padding(.top, 8)
                if let line = flow.errorLine ?? blocked {
                    Text(line)
                        .font(type.body(t.font.scale.caption, t.font.weights.strong))
                        .foregroundColor(.graineHex(c.danger))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func label(_ words: String, _ t: GraineThemeTokens, _ type: GraineType) -> some View {
        Text(words)
            .font(type.body(t.font.scale.caption, t.font.weights.strong))
            .tracking(type.bodyTracking(t.font.scale.caption))
            .foregroundColor(.graineHex(t.colors.textMuted))
    }

    /// A day: 34 high, the starters' corners; the picked one in the accent.
    private func chip(_ words: String, selected: Bool, _ t: GraineThemeTokens, _ type: GraineType, _ pick: @escaping () -> Void) -> some View {
        let c = t.colors
        let shape = RoundedRectangle(cornerRadius: CGFloat(min(t.shape.radius.xl, 17)), style: .continuous)
        return Button(action: pick) {
            Text(words)
                .font(type.body(t.font.scale.body - 1, t.font.weights.strong))
                .foregroundColor(.graineHex(selected ? c.onAccent : c.text))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(shape.fill(Color.graineHex(selected ? c.accent : c.surfaceRaised)))
                .overlay(shape.strokeBorder(Color.graineHex(selected ? c.accent : c.border), lineWidth: CGFloat(max(1, t.shape.borderWidth))))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(flow.isBooking)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// One line, in the chat composer's colours; 120 characters, as the server keeps.
    private func reasonField(_ t: GraineThemeTokens, _ type: GraineType) -> some View {
        let c = t.colors
        let chat = t.chat
        let shape = RoundedRectangle(cornerRadius: CGFloat(t.shape.radius.md), style: .continuous)
        return TextField("", text: Binding(get: { flow.reason }, set: { flow.setReason($0) }))
            .font(type.body(t.font.scale.body, t.font.weights.body))
            .foregroundColor(.graineHex(chat?.composerText ?? c.text))
            .submitLabel(.done)
            .disabled(flow.isBooking)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(shape.fill(Color.graineHex(chat?.composerBackground ?? c.surfaceRaised)))
            .overlay(shape.strokeBorder(Color.graineHex(chat?.composerBorder ?? c.border), lineWidth: CGFloat(max(1, t.shape.borderWidth))))
            .accessibilityLabel(Booking.reasonLabel)
    }

    /// "Book call": the accent, full width; a spinner while it books.
    private func bookButton(_ t: GraineThemeTokens, _ type: GraineType, enabled: Bool) -> some View {
        let c = t.colors
        let onAccent = Color.graineHex(c.onAccent, fallback: .white)
        let shape = RoundedRectangle(cornerRadius: CGFloat(t.shape.radius.md), style: .continuous)
        let busy = flow.isBooking
        return Button(action: book) {
            ZStack {
                if busy {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: onAccent))
                } else {
                    Text(Booking.bookButton)
                        .font(type.body(t.font.scale.body, t.font.weights.strong))
                        .foregroundColor(onAccent)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(shape.fill(Color.graineHex(c.accent)))
            .contentShape(shape)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!enabled || busy)
        .opacity(enabled ? 1 : VoiceBar.blockedOpacity)
        .accessibilityLabel(busy ? "Booking" : Booking.bookButton)
    }

    private func book() {
        guard let request = flow.begin() else { return }
        onBusy?(true)
        Task { @MainActor in
            let result: Result<GraineScheduledCall, Error>
            do {
                result = .success(try await graine.scheduleCall(at: request.at, reason: request.reason))
            } catch {
                result = .failure(error)
            }
            withAnimation(tokens.motion.animation(reduceMotion: reduceMotion)) { flow.finish(result, now: Date()) }
            onBusy?(false)
            if case .success(let call) = result { onBooked?(call) }
        }
    }

    // MARK: Booked

    private func confirmation(_ t: GraineThemeTokens, _ type: GraineType, _ call: GraineScheduledCall) -> some View {
        let c = t.colors
        let accent = Color.graineHex(c.accent)
        let onAccent = Color.graineHex(c.onAccent, fallback: .white)
        let shape = RoundedRectangle(cornerRadius: CGFloat(t.shape.radius.md), style: .continuous)
        return VStack(spacing: 18) {
            ZStack {
                Circle().fill(accent)
                GraineIconView(name: .call, style: t.icons.style, stroke: t.icons.stroke, color: onAccent, size: 24)
            }
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)
            Text(Booking.bookedLine(callName: callName, at: call.at ?? flow.at))
                .font(type.body(t.font.scale.body, t.font.weights.strong))
                .foregroundColor(.graineHex(c.text))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { onClose(call) }) {
                Text(Booking.doneButton)
                    .font(type.body(t.font.scale.body, t.font.weights.strong))
                    .foregroundColor(onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(shape.fill(accent))
                    .contentShape(shape)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }
}

// MARK: - The time wheel

/**
 * The system's time wheel (UIDatePicker, hour and minute, every 5 minutes),
 * holding only the times between `minimum` and `maximum` — the picked day's.
 * In the design's light or dark, the accent as its tint.
 */
struct GraineTimeWheel: UIViewRepresentable {
    @Binding var date: Date
    let minimum: Date
    let maximum: Date
    let dark: Bool
    let tint: UIColor

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .wheels
        picker.minuteInterval = Booking.minuteStep
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        picker.accessibilityLabel = Booking.timeLabel
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {
        context.coordinator.parent = self
        picker.overrideUserInterfaceStyle = dark ? .dark : .light
        picker.tintColor = tint
        picker.minimumDate = minimum
        picker.maximumDate = maximum
        if abs(picker.date.timeIntervalSince(date)) >= 1 { picker.setDate(date, animated: false) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: GraineTimeWheel
        init(_ parent: GraineTimeWheel) { self.parent = parent }

        @objc func changed(_ picker: UIDatePicker) {
            parent.date = picker.date
        }
    }
}
#endif
