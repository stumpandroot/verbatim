import SwiftUI

/// The iPhone's side of Record a call (Model/CallRelay.swift; approved mockup "Verbose License and Calls", section 3):
/// reads what the Mac wrote (that it's there, its next call, the wait it holds) and writes the request to wait or
/// cancel. Only with iCloud sync on.
@MainActor
final class PhoneCallRelay: ObservableObject {
    static let shared = PhoneCallRelay()
    @Published private(set) var mac: CallRelayMac? = nil
    private var timer: Timer?

    private var macURL: URL? { Cloud.root?.appendingPathComponent(CallRelay.macFileName) }
    private var requestURL: URL? { Cloud.root?.appendingPathComponent(CallRelay.requestFileName) }

    /// Reads now and every 30 seconds while the app is in front.
    func start() {
        guard Cloud.enabled, timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        guard let url = macURL else { mac = nil; return }
        Task {
            _ = await Cloud.ensureDownloaded(url, timeout: 10)
            let m = (try? Data(contentsOf: url)).flatMap(CallRelay.decodeMac)
            if m != mac { mac = m }
        }
    }

    var state: CallRelay.MacState { CallRelay.macState(mac, now: Date()) }
    var nextCall: CallRelayEvent? { CallRelay.nextCall(mac, now: Date()) }
    var activeWait: CallRelayWait? { CallRelay.activeWait(mac, now: Date()) }

    /// Asks the Mac to wait for its next call (or any call app), or to cancel.
    @discardableResult
    func send(_ action: CallRelayRequest.Action, eventID: String? = nil, copyNotice: Bool = true) -> Bool {
        guard let url = requestURL else { return false }
        let r = CallRelayRequest(id: UUID().uuidString, action: action, eventID: eventID, copyNotice: copyNotice,
                                 created: Date(), device: Device.id, deviceName: Device.name)
        guard let data = try? CallRelay.encoder().encode(r) else { return false }
        do { try data.write(to: url, options: .atomic) } catch { return false }
        Log.note("calls: asked the Mac to \(action == .wait ? "wait for a call" : "cancel the wait")")
        return true
    }
}

/// Record a call: three ways that work on iPhone, the Mac first when there is one.
struct PhoneCallSheet: View {
    enum Way: Hashable { case mac, speaker, phone }
    @Environment(PhoneState.self) private var app
    @ObservedObject private var relay = PhoneCallRelay.shared
    @Environment(\.dismiss) private var dismiss
    @State private var way: Way = .mac
    @State private var copyNotice = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    option(.mac, CallRelay.onMac, macDetail)
                    option(.speaker, CallRelay.onSpeaker, CallRelay.onSpeakerDetail)
                    option(.phone, CallRelay.phoneCall, CallRelay.phoneCallDetail)
                    if way == .mac, macReady {
                        Toggle(CallRelay.copyNotice, isOn: $copyNotice).refinedFont(.hint).tint(Refined.accentText)
                        Text(CallRelay.consent + " " + CallRelay.asleepNote).refinedFont(.hint).foregroundStyle(Refined.mute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: go) {
                    Text(buttonTitle).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.paper)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Refined.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(RefinedPress())
                .disabled(way == .mac && !macReady)
                .opacity(way == .mac && !macReady ? 0.45 : 1)
                .padding(16)
                .accessibilityIdentifier("call.go")
            }
            .background(Refined.paper)
            .navigationTitle(CallRelay.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onAppear { relay.start(); relay.refresh(); if !macReady { way = .speaker } }
    }

    private var macReady: Bool { if case .ready = relay.state { return true }; return false }

    private var macDetail: String {
        switch relay.state {
        case .none: return CallRelay.noMac
        case .stale(let name, let days): return CallRelay.staleMac(name, days: days)
        case .ready(let name):
            return CallRelay.onMacDetail(next: relay.nextCall, macName: name) { Formats.style(date: .none, time: .short).string(from: $0) }
        }
    }

    private var buttonTitle: String {
        switch way {
        case .mac: return CallRelay.waitButton
        case .speaker: return "Record on speaker"
        case .phone: return "OK"
        }
    }

    private func option(_ w: Way, _ title: String, _ detail: String) -> some View {
        Button { way = w } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                Text(detail).refinedFont(.hint).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .refinedSurface(Refined.card, radius: RefinedPlatform.radius(.card))
            .overlay {
                if way == w { RoundedRectangle(cornerRadius: RefinedPlatform.radius(.card), style: .continuous).stroke(Refined.accentText, lineWidth: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(way == w ? [.isButton, .isSelected] : .isButton)
    }

    private func go() {
        switch way {
        case .mac:
            if relay.send(.wait, eventID: relay.nextCall?.id, copyNotice: copyNotice) {
                app.say(CallRelay.sent)
                Haptics.play(.mark)
            } else {
                app.say("Couldn't reach your Mac. Check that iCloud sync is on.")
            }
            dismiss()
        case .speaker:
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { app.startRecordChoice(.kind(.meeting)) }
        case .phone:
            dismiss()
        }
    }
}

/// Home's card while your Mac waits for a call you set up from here (or any wait it holds), with Cancel.
struct PhoneCallWaitCard: View {
    var top: CGFloat = 0
    @ObservedObject private var relay = PhoneCallRelay.shared

    var body: some View {
        Group {
            if let w = relay.activeWait {
                VStack(alignment: .leading, spacing: 6) {
                    Text(w.recording ? "Recording your call" : CallRelay.waitingTitle).refinedFont(.rowTitle, weight: .semibold).foregroundStyle(Refined.ink)
                    Text(CallRelay.waitingBody(w, macName: relay.mac?.name ?? Device.name.replacingOccurrences(of: "iPhone", with: "Mac")))
                        .refinedFont(.hint).foregroundStyle(Refined.dim).fixedSize(horizontal: false, vertical: true)
                    if !w.recording {
                        Button("Cancel") { if relay.send(.cancel) { relay.refresh() } }
                            .refinedFont(.hint, weight: .semibold).foregroundStyle(Refined.accentText)
                            .frame(minHeight: CGFloat(RefinedRules.minTapTarget))
                    }
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, w.recording ? 14 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .refinedSurface(Refined.persimmonTint, radius: RefinedPlatform.radius(.card))
                .padding(.top, top)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home.callWait")
            }
        }
        .onAppear { relay.start() }
    }
}
