import SwiftUI

// Plan my day's sections and Audio only's waveform, shared by the Mac and the iPhone (approved mockup "Verbose Brain
// Dump", October 27, 2026; DayPlan.swift, AudioOnly.swift), on the refined kit (DESIGN.md §13).
//
// Section titles in the serif, tasks with an empty ring to tick, ideas as bullets (they aren't things to check off),
// and each task's time at the trailing end in the accent, which opens the line it came from. Plans and kinds are
// neutral: no persimmon, butter, sage, or petal fill on a plan. Sent tasks show the accent's check and "In Reminders".

struct PlanSections: View {
    var plan: DayPlan
    var recordedAt: Date
    var sent: [String: String] = [:]
    /// Section title and body sizes: the iPhone's 20 and 16, the Mac's 17 and 13.
    var headingSize: CGFloat = 20
    var textSize: CGFloat = 16
    /// The link after an item: "0:04", "7:12 AM · iPhone", "¶2". nil draws none.
    var link: (DayPlan.Item) -> String? = { $0.anchor.map(DayPlan.clock) }
    /// Tapping the link: play that line, jump to the thought, or select the paragraph.
    var onJump: ((DayPlan.Item) -> Void)? = nil
    /// VoiceOver's Send to Reminders action on a task.
    var onSend: ((DayPlan.Item) -> Void)? = nil
    /// Mac: the pointer is over an item (its sentence underlines in the note).
    var onHover: ((DayPlan.Item?) -> Void)? = nil

    var body: some View {
        if plan.isEmpty {
            Text(DayPlan.noTasksLine).font(.system(size: textSize)).foregroundStyle(Refined.mute)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(plan.shownSections, id: \.self) { sec in
                    heading(sec)
                        .padding(.top, sec == plan.shownSections.first ? 0 : 12)
                    if sec == .top, plan.topInferred { note(DayPlan.topInferredLine) }
                    if sec == .someday { note(DayPlan.somedayLine) }
                    ForEach(Array(plan.items(sec).enumerated()), id: \.element.id) { i, item in
                        row(item, number: sec == .top ? i + 1 : nil)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func heading(_ sec: DayPlan.Section) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(sec == .top ? "Top three" : sec.title).font(.system(size: headingSize, design: .serif))
                .foregroundStyle(Refined.ink)
            if sec == .tomorrow {
                Text(DayPlan.tomorrowLabel(recordedAt: recordedAt)).font(.system(size: max(12, textSize - 3))).foregroundStyle(Refined.mute)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: textSize - 2)).foregroundStyle(Refined.mute).fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ item: DayPlan.Item, number: Int?) -> some View {
        let isSent = sent[item.key] != nil
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let number {
                Text("\(number)").font(.system(size: max(12, textSize - 3))).monospacedDigit().foregroundStyle(Refined.mute)
                    .frame(minWidth: 12, alignment: .leading)
                    .accessibilityHidden(true)
            }
            if item.isIdea {
                Circle().fill(Refined.mute).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + textSize * 0.28 }
                    .frame(width: textSize * 0.95).accessibilityHidden(true)
            } else {
                RefinedCheckbox(on: isSent, size: textSize * 0.95)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    words(item, isSent: isSent)
                    Spacer(minLength: 6)
                    trailing(item, isSent: isSent)
                }
                // Larger text: the time drops under the task.
                VStack(alignment: .leading, spacing: 2) {
                    words(item, isSent: isSent)
                    trailing(item, isSent: isSent)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { inside in onHover?(inside ? item : nil) }
        .modifier(PlanItemAccessibility(item: item, recordedAt: recordedAt, sent: isSent, link: link(item), onJump: onJump, onSend: onSend))
    }

    private func words(_ item: DayPlan.Item, isSent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.text).font(.system(size: textSize)).foregroundStyle(isSent ? Refined.dim : Refined.ink).fixedSize(horizontal: false, vertical: true)
            if let w = item.weekday, item.section == .week {
                Text(DayPlan.weekdayShort(w)).font(.system(size: max(12, textSize - 3))).foregroundStyle(Refined.mute)
            }
        }
    }

    @ViewBuilder private func trailing(_ item: DayPlan.Item, isSent: Bool) -> some View {
        HStack(spacing: 8) {
            if isSent {
                Text("In Reminders").font(.system(size: max(12, textSize - 3))).foregroundStyle(Refined.mute)
            } else if let l = link(item) {
                Button { onJump?(item) } label: {
                    Text(l).font(.system(size: max(12, textSize - 3))).monospacedDigit().foregroundStyle(onJump == nil ? Refined.mute : Refined.accentText)
                }
                .buttonStyle(.plain)
                .disabled(onJump == nil)
                .accessibilityHidden(true)
            }
        }
        .fixedSize()
    }
}

/// A plan item for VoiceOver: its words, its day, and "said at 0:04", with an action to play that line and one to
/// send it to Reminders.
private struct PlanItemAccessibility: ViewModifier {
    var item: DayPlan.Item
    var recordedAt: Date
    var sent: Bool
    var link: String?
    var onJump: ((DayPlan.Item) -> Void)?
    var onSend: ((DayPlan.Item) -> Void)?

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityAction(named: "Play that line") { onJump?(item) }
            .accessibilityAction(named: "Send to Reminders") { if !sent { onSend?(item) } }
    }

    private var label: String {
        var parts = [item.text]
        if !item.isIdea {
            let due = DayPlan.due(item, recordedAt: recordedAt)
            parts.append(due == nil ? "no day" : DayPlan.dueLabel(due))
        } else {
            parts.append("idea")
        }
        if let link { parts.append("said at \(link)") }
        if sent { parts.append("in Reminders") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Audio only's waveform

/// An Audio only recording's sound, drawn from its saved levels (`Transcript.waveform`): the played part in the
/// playback color, the rest in ink (or label color), and each moment as a tick. One Canvas, no per-bar views.
struct AudioWave: View {
    var levels: [Float]
    /// 0…1 of the way through.
    var played: Double = 0
    /// Each moment, 0…1 of the way through.
    var marks: [Double] = []
    var bar: Color
    var playedColor: Color
    var mark: Color
    var bars = 54

    var body: some View {
        Canvas { ctx, size in
            let n = max(8, bars)
            let gap: CGFloat = 2
            let w = max(1.5, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            let values = Self.resample(levels, to: n)
            for i in 0..<n {
                let h = max(3, CGFloat(values[i]) * size.height)
                let x = CGFloat(i) * (w + gap)
                let r = CGRect(x: x, y: (size.height - h) / 2, width: w, height: h)
                let color = Double(i) / Double(n) < played ? playedColor : bar
                ctx.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .color(color))
            }
            for m in marks where m >= 0 && m <= 1 {
                let x = CGFloat(m) * size.width
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(mark))
            }
        }
        .accessibilityHidden(true)
    }

    /// The saved levels at `n` bars, never flat: a recording with none draws a quiet even line.
    static func resample(_ levels: [Float], to n: Int) -> [Float] {
        guard !levels.isEmpty else { return Array(repeating: 0.12, count: n) }
        return (0..<n).map { i in
            let a = Int(Double(i) / Double(n) * Double(levels.count))
            let b = max(a + 1, Int(Double(i + 1) / Double(n) * Double(levels.count)))
            let slice = levels[min(a, levels.count - 1)..<min(b, levels.count)]
            let peak = slice.max() ?? 0
            return min(1, max(0.08, peak))
        }
    }

    /// The moments' places along the recording, for the ticks.
    static func marks(_ t: Transcript) -> [Double] {
        guard t.duration > 0 else { return [] }
        return t.notes.compactMap { $0.at }.map { $0 / t.duration }
    }
}
