import Foundation

// Which microphone an iPhone recording uses, what the Record card's ready chip and the recorder's microphone menu
// call it, and how the audio session is set up for it (DESIGN.md §6.10, Recording input). Foundation only: the iPhone
// turns AVAudioSession's port descriptions into `RecordingInput`s (RecordingRoute in Audio/Recorder.swift), and
// mac/tools/test-recording-input.sh checks these rules on Linux. The iPhone's self-test runs the same cases from a
// mocked route (`RecordingInputChecks`).

/// An audio input as a recording sees it.
struct RecordingInput: Equatable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        /// The iPhone's own microphone.
        case builtIn
        /// AirPods and other Bluetooth headsets (HFP, LE, or AirPods' high-quality link on iOS 26).
        case bluetooth
        /// A headset or line input on the Lightning or USB-C port's adapter.
        case wired
        /// A USB microphone or interface.
        case usb
        /// CarPlay's microphone.
        case car
        /// Anything else iOS lists (a Continuity microphone, a port type a newer iOS adds).
        case other
    }

    var uid: String
    var name: String
    var kind: Kind

    init(uid: String, name: String, kind: Kind) {
        self.uid = uid; self.name = name; self.kind = kind
    }

    var isAccessory: Bool { kind != .builtIn }
}

enum RecordingInputRules {
    /// Which accessory wins when the route hasn't picked one: what you plugged in, then what you wear.
    static let accessoryOrder: [RecordingInput.Kind] = [.usb, .wired, .bluetooth, .car, .other]

    /// The input a recording uses:
    /// 1. The one you chose for this recording in the recorder's microphone menu, while it's there.
    /// 2. The accessory iOS already routes to (AirPods you just put in, the headset you plugged in).
    /// 3. Any accessory that's there, in `accessoryOrder`, so AirPods win over the iPhone's microphone.
    /// 4. The iPhone's microphone.
    /// Nil only when nothing is listed at all.
    static func choose(available: [RecordingInput], current: String?, chosen: String?) -> RecordingInput? {
        if let chosen, let c = available.first(where: { $0.uid == chosen }) { return c }
        if let current, let c = available.first(where: { $0.uid == current }), c.isAccessory { return c }
        for kind in accessoryOrder {
            if let c = available.first(where: { $0.kind == kind }) { return c }
        }
        return available.first(where: { $0.kind == .builtIn }) ?? available.first
    }

    /// What the chip and the menu call an input: "iPhone microphone" for the built-in one (sentence case, as the
    /// mockup writes it), and the accessory's own name otherwise ("AirPods Pro", "Tim's AirPods Pro"), or what it is
    /// when it has none.
    static func displayName(_ input: RecordingInput?) -> String {
        guard let input else { return builtInName }
        if input.kind == .builtIn { return builtInName }
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        switch input.kind {
        case .bluetooth: return "Bluetooth headset"
        case .wired: return "Headset microphone"
        case .usb: return "USB microphone"
        case .car: return "Car microphone"
        case .builtIn, .other: return "Microphone"
        }
    }

    static let builtInName = "iPhone microphone"

    /// The Record card's chip at rest: "Ready · AirPods Pro", or "Ready · iPhone microphone".
    static func readyText(_ input: RecordingInput?) -> String { "Ready \u{00B7} " + displayName(input) }

    /// The recorder's microphone menu: the iPhone's microphone first, then the accessories in `accessoryOrder`,
    /// each once (an input iOS lists twice, by its output and its input, shows once).
    static func menu(_ available: [RecordingInput]) -> [RecordingInput] {
        var seen = Set<String>()
        let unique = available.filter { seen.insert($0.uid).inserted }
        let builtIn = unique.filter { $0.kind == .builtIn }
        let rest = accessoryOrder.flatMap { k in unique.filter { $0.kind == k } }
        return builtIn + rest
    }

    /// The inputs a recording could use, from what iOS lists. Before the first recording the app's session isn't a
    /// recording session, so iOS lists no microphones for it; a Bluetooth headset on the output (AirPods playing
    /// music) is the input a recording will use then, and the iPhone's microphone is always there.
    static func known(inputs: [RecordingInput], bluetoothOutputs: [RecordingInput], sessionRecords: Bool) -> [RecordingInput] {
        var list: [RecordingInput] = []
        var seen = Set<String>()
        for i in inputs where seen.insert(i.uid).inserted { list.append(i) }
        if !sessionRecords {
            for o in bluetoothOutputs where !list.contains(where: { $0.kind == .bluetooth && $0.name == o.name }) {
                if seen.insert(o.uid).inserted { list.append(RecordingInput(uid: o.uid, name: o.name, kind: .bluetooth)) }
            }
        }
        if !list.contains(where: { $0.kind == .builtIn }) {
            list.append(RecordingInput(uid: builtInPlaceholder, name: builtInName, kind: .builtIn))
        }
        return list
    }

    /// Stands in for the iPhone's microphone before iOS lists it.
    static let builtInPlaceholder = "builtin"

    // MARK: The audio session

    /// The session mode a recording asks for.
    enum Mode: String, Sendable {
        /// `.default`: the only mode AirPods' high-quality recording works in (Apple's documentation for
        /// `bluetoothHighQualityRecording`).
        case standard
        /// `.spokenAudio`: voice notes, meetings, thoughts, and brain dumps on the iPhone's microphone or a wired one.
        case spokenAudio
        /// `.measurement`: Audio only on the iPhone's microphone or a wired one, with the system's voice processing off.
        case measurement
    }

    struct SessionPlan: Equatable, Sendable {
        var mode: Mode
        /// Ask for AirPods' high-quality link (`.bluetoothHighQualityRecording`), with HFP as the fallback.
        var highQuality: Bool
    }

    /// How the session is set up for an input. A Bluetooth input on iOS 26 asks for the high-quality link, which
    /// needs the default mode (in Audio only too: it's what gives AirPods their full rate); before iOS 26, and on
    /// every other input, voice recordings use spoken audio and Audio only measurement, without the high-quality
    /// option, which iOS rejects outside the default mode.
    static func plan(for input: RecordingInput?, soundOnly: Bool, highQualityAvailable: Bool) -> SessionPlan {
        if input?.kind == .bluetooth && highQualityAvailable { return SessionPlan(mode: .standard, highQuality: true) }
        return SessionPlan(mode: soundOnly ? .measurement : .spokenAudio, highQuality: false)
    }

    /// The plan a running recording switches to when it moves to `input` (the microphone menu, or the automatic move
    /// when its input goes), or nil when the plan in force (`current`) already fits. AirPods taken out of an Audio only
    /// recording put the iPhone microphone back in measurement mode; a voice note back in spoken audio.
    static func replan(moving input: RecordingInput?, soundOnly: Bool, highQualityAvailable: Bool, current: SessionPlan?) -> SessionPlan? {
        let next = plan(for: input, soundOnly: soundOnly, highQualityAvailable: highQualityAvailable)
        return next == current ? nil : next
    }

    /// Whether a recording that's running should move: a change it didn't ask for keeps the input it has while that
    /// input is there (AirPods coming up on their high-quality link, a sample rate change), and moves to the best
    /// input left only when it's gone.
    static func afterRouteChange(pinned: String?, available: [RecordingInput]) -> RecordingInput? {
        if let pinned, let p = available.first(where: { $0.uid == pinned }) { return p }
        return choose(available: available, current: nil, chosen: nil)
    }
}

/// The recording-input rules, checked by the Linux tests (`mac/tools/test-recording-input.sh`) and by the iPhone's
/// self-test from a mocked route. `check` logs PASS or FAIL.
enum RecordingInputChecks {
    static let builtIn = RecordingInput(uid: "Built-In Microphone", name: "iPhone Microphone", kind: .builtIn)
    static let airPods = RecordingInput(uid: "AA:BB:CC:DD:EE:FF-tsco", name: "AirPods Pro", kind: .bluetooth)
    static let wired = RecordingInput(uid: "Wired Microphone", name: "Headset Microphone", kind: .wired)
    static let usb = RecordingInput(uid: "AppleUSBAudioEngine:Shure", name: "MV7", kind: .usb)

    static func run(_ check: (String, Bool) -> Void) {
        typealias R = RecordingInputRules
        let both = [builtIn, airPods]
        check("input: AirPods win over the iPhone microphone when the route still says iPhone",
              R.choose(available: both, current: builtIn.uid, chosen: nil) == airPods)
        check("input: AirPods win when iOS already routes to them", R.choose(available: both, current: airPods.uid, chosen: nil) == airPods)
        check("input: the iPhone microphone when nothing else is there", R.choose(available: [builtIn], current: builtIn.uid, chosen: nil) == builtIn)
        check("input: the one you chose for this recording wins", R.choose(available: both, current: airPods.uid, chosen: builtIn.uid) == builtIn)
        check("input: a choice that's gone falls back to the rules", R.choose(available: both, current: nil, chosen: "gone") == airPods)
        check("input: a plugged-in microphone beats AirPods", R.choose(available: [builtIn, airPods, usb], current: nil, chosen: nil) == usb
              && R.choose(available: [builtIn, airPods, wired], current: builtIn.uid, chosen: nil) == wired)
        check("input: the accessory iOS picked stays picked", R.choose(available: [builtIn, airPods, wired], current: airPods.uid, chosen: nil) == airPods)
        check("input: nothing listed is nil", R.choose(available: [], current: nil, chosen: nil) == nil)

        check("chip: Ready · AirPods Pro with AirPods in", R.readyText(R.choose(available: both, current: builtIn.uid, chosen: nil)) == "Ready \u{00B7} AirPods Pro")
        check("chip: Ready · iPhone microphone, in sentence case", R.readyText(builtIn) == "Ready \u{00B7} iPhone microphone" && R.readyText(nil) == "Ready \u{00B7} iPhone microphone")
        check("chip: an accessory with no name says what it is",
              R.displayName(RecordingInput(uid: "x", name: " ", kind: .bluetooth)) == "Bluetooth headset"
              && R.displayName(RecordingInput(uid: "y", name: "", kind: .usb)) == "USB microphone")

        // At rest, before any recording: no inputs listed, AirPods on the output.
        let output = RecordingInput(uid: "AA:BB:CC:DD:EE:FF", name: "AirPods Pro", kind: .bluetooth)
        let rest = R.known(inputs: [], bluetoothOutputs: [output], sessionRecords: false)
        check("chip at rest: AirPods playing music are the input a recording will use",
              R.readyText(R.choose(available: rest, current: nil, chosen: nil)) == "Ready \u{00B7} AirPods Pro")
        check("chip at rest: the iPhone microphone is always listed", rest.contains { $0.kind == .builtIn })
        check("chip at rest: no headset, the iPhone microphone",
              R.readyText(R.choose(available: R.known(inputs: [], bluetoothOutputs: [], sessionRecords: false), current: nil, chosen: nil)) == "Ready \u{00B7} iPhone microphone")
        let recording = R.known(inputs: [builtIn, airPods], bluetoothOutputs: [output], sessionRecords: true)
        check("chip: a recording session's own list is used as is, each input once",
              recording == [builtIn, airPods] && R.known(inputs: [builtIn, builtIn], bluetoothOutputs: [], sessionRecords: true).count == 1)

        check("menu: the iPhone microphone first, then the accessories, each once",
              R.menu([airPods, usb, builtIn, airPods, wired]) == [builtIn, usb, wired, airPods])

        check("session: AirPods on iOS 26 ask for the high-quality link in the default mode, for every kind",
              R.plan(for: airPods, soundOnly: false, highQualityAvailable: true) == .init(mode: .standard, highQuality: true)
              && R.plan(for: airPods, soundOnly: true, highQualityAvailable: true) == .init(mode: .standard, highQuality: true))
        check("session: the high-quality option is never asked for outside the default mode",
              [builtIn, airPods, wired, usb].allSatisfy { i in [true, false].allSatisfy { s in [true, false].allSatisfy { h in
                  let p = R.plan(for: i, soundOnly: s, highQualityAvailable: h); return !p.highQuality || p.mode == .standard } } })
        check("session: before iOS 26, AirPods use spoken audio over HFP",
              R.plan(for: airPods, soundOnly: false, highQualityAvailable: false) == .init(mode: .spokenAudio, highQuality: false))
        check("session: the iPhone microphone keeps spoken audio, and Audio only keeps measurement",
              R.plan(for: builtIn, soundOnly: false, highQualityAvailable: true) == .init(mode: .spokenAudio, highQuality: false)
              && R.plan(for: builtIn, soundOnly: true, highQualityAvailable: true) == .init(mode: .measurement, highQuality: false))

        check("route change: a recording on AirPods stays on them while they're there",
              R.afterRouteChange(pinned: airPods.uid, available: both) == airPods)
        check("route change: AirPods taken out move the recording to the iPhone microphone",
              R.afterRouteChange(pinned: airPods.uid, available: [builtIn]) == builtIn)
        check("route change: a change never moves a recording off the input it has to the iPhone microphone",
              R.afterRouteChange(pinned: airPods.uid, available: [builtIn, airPods, wired]) == airPods)
        let onAirPods = R.plan(for: airPods, soundOnly: true, highQualityAvailable: true)
        check("route change: AirPods taken out of Audio only put the iPhone microphone back in measurement, without the high-quality option",
              R.replan(moving: R.afterRouteChange(pinned: airPods.uid, available: [builtIn]), soundOnly: true, highQualityAvailable: true,
                       current: onAirPods) == .init(mode: .measurement, highQuality: false))
        check("route change: AirPods taken out of a voice note put the iPhone microphone back in spoken audio",
              R.replan(moving: builtIn, soundOnly: false, highQualityAvailable: true,
                       current: R.plan(for: airPods, soundOnly: false, highQualityAvailable: true)) == .init(mode: .spokenAudio, highQuality: false))
        check("route change: a move to an input with the same plan leaves the session alone",
              R.replan(moving: wired, soundOnly: false, highQualityAvailable: true, current: R.plan(for: builtIn, soundOnly: false, highQualityAvailable: true)) == nil
              && R.replan(moving: builtIn, soundOnly: true, highQualityAvailable: false, current: R.plan(for: airPods, soundOnly: true, highQualityAvailable: false)) == nil)
        check("route change: a move with no plan in force sets one up",
              R.replan(moving: builtIn, soundOnly: false, highQualityAvailable: true, current: nil) == .init(mode: .spokenAudio, highQuality: false))
    }
}
