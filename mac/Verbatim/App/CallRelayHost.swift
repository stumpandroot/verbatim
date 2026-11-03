import Foundation
import Combine

/// The Mac's side of Record a call from the iPhone (Model/CallRelay.swift): writes calls-mac.json (that it's here,
/// its next calendar call, and the wait it holds) and acts once on each fresh calls-request.json from the iPhone. Only
/// with iCloud sync on, since the files ride in the synced folder.
@MainActor
final class CallRelayHost {
    static let shared = CallRelayHost()

    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var lastWritten: CallRelayMac?
    private static let handledKey = "callRelay.lastHandled"

    private var macURL: URL? { Cloud.root?.appendingPathComponent(CallRelay.macFileName) }
    private var requestURL: URL? { Cloud.root?.appendingPathComponent(CallRelay.requestFileName) }

    func start() {
        guard Cloud.enabled, timer == nil else { return }
        let c = MeetingCoordinator.shared
        c.$wait.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.writeStatus() } }.store(in: &bag)
        MeetingSession.shared.$phase.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.writeStatus() } }.store(in: &bag)
        CallCalendar.shared.$events.sink { [weak self] _ in DispatchQueue.main.async { self?.writeStatus() } }.store(in: &bag)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func tick() {
        readRequest()
        if let w = lastWritten, Date().timeIntervalSince(w.seen) < CallRelay.heartbeat { writeStatus(onlyIfChanged: true) } else { writeStatus() }
    }

    private func readRequest() {
        guard let url = requestURL, let data = try? Data(contentsOf: url), let r = CallRelay.decodeRequest(data) else { return }
        let last = UserDefaults.standard.string(forKey: Self.handledKey)
        guard CallRelay.shouldHandle(r, lastHandled: last, now: Date()) else { return }
        UserDefaults.standard.set(r.id, forKey: Self.handledKey)
        let c = MeetingCoordinator.shared
        switch r.action {
        case .wait:
            c.armFromPhone(eventID: r.eventID, copyNotice: r.copyNotice, requestID: r.id)
        case .cancel:
            if c.wait != nil { c.cancelWait() }
        }
        writeStatus()
    }

    private func writeStatus(onlyIfChanged: Bool = false) {
        guard let url = macURL else { return }
        let now = Date()
        let c = MeetingCoordinator.shared
        let next = CallCalendar.shared.next(now: now).map {
            CallRelayEvent(id: $0.id, title: $0.title, start: $0.start, end: $0.end, service: $0.service.name)
        }
        var wait: CallRelayWait? = c.wait.map {
            CallRelayWait(appName: $0.appName, title: $0.title, expires: $0.expires, requestID: c.phoneRequestID)
        }
        if wait == nil, MeetingSession.shared.isActive, let id = c.phoneRequestID {
            wait = CallRelayWait(appName: "the call app", title: nil, expires: now.addingTimeInterval(3600), requestID: id, recording: true)
        }
        var status = CallRelayMac(device: Device.id, name: Device.name, seen: now, next: next, wait: wait)
        if onlyIfChanged, let last = lastWritten {
            var a = last; a.seen = now
            if a == status { return }
        }
        status.seen = now
        guard let data = try? CallRelay.encoder().encode(status) else { return }
        try? data.write(to: url, options: .atomic)
        lastWritten = status
    }
}
