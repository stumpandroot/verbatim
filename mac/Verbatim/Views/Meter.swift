import SwiftUI
import Combine

/// The fast-changing part of a recording: level bars and elapsed time. Its own object so only the views that
/// show it re-render (about 14 times a second); nothing else in the app hears about it.
@MainActor
final class LiveMeter: ObservableObject {
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 28)
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0
    private var pendingPeak: Float = 0
    private var last = Date.distantPast

    /// Called per audio buffer. Coalesces into one publish every 70 ms.
    func push(_ v: Float, seconds: TimeInterval, paused: Bool) {
        pendingPeak = max(pendingPeak, paused ? 0 : v)
        let now = Date()
        guard now.timeIntervalSince(last) > 0.07 else { return }
        last = now
        elapsed = seconds
        if !paused {
            level = pendingPeak
            var l = levels; l.removeFirst(); l.append(pendingPeak); levels = l
        }
        pendingPeak = 0
    }
    func reset() { levels = Array(repeating: 0, count: 28); level = 0; elapsed = 0; pendingPeak = 0 }
    func setElapsed(_ s: TimeInterval) { elapsed = s }
}

import AppKit
import QuartzCore

/// Live audio meter drawn with Core Animation bars. Heights arrive from the recorder a few times a
/// second; the render server interpolates between them, so SwiftUI never runs per frame.
/// Elapsed time + bars, observing only the LiveMeter so the rest of the app stays still while recording.
struct LiveReadout: View {
    @ObservedObject var live: LiveMeter
    var color: NSColor = NSColor(red: 1, green: 0x7C/255, blue: 0x5C/255, alpha: 1)
    var frozen = false
    var showTime = true
    var body: some View {
        HStack(spacing: 14) {
            if showTime {
                Text(live.elapsed.timecode).font(.system(size: 14, design: .monospaced)).foregroundStyle(Ink.ink).frame(minWidth: 56, alignment: .leading)
            }
            Meter(levels: live.levels, color: color, frozen: frozen).frame(height: 26).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Meter: NSViewRepresentable {
    var levels: [Float]
    var color: NSColor = NSColor(red: 1, green: 0x7C/255, blue: 0x5C/255, alpha: 1)
    var frozen = false

    func makeNSView(context: Context) -> MeterHost { let v = MeterHost(); v.color = color; v.apply(levels, frozen: frozen); return v }
    func updateNSView(_ v: MeterHost, context: Context) { v.color = color; v.apply(levels, frozen: frozen) }
}

final class MeterHost: NSView {
    var color = NSColor.systemOrange { didSet { bars.forEach { $0.backgroundColor = color.cgColor } } }
    private var bars: [CALayer] = []
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true }

    func apply(_ levels: [Float], frozen: Bool) {
        if bars.count != levels.count {
            bars.forEach { $0.removeFromSuperlayer() }
            bars = levels.map { _ in let l = CALayer(); l.backgroundColor = color.cgColor; l.cornerRadius = 1.5; layer?.addSublayer(l); return l }
        }
        let h = bounds.height
        CATransaction.begin()
        CATransaction.setAnimationDuration(frozen ? 0 : 0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (i, l) in bars.enumerated() {
            let bh = max(3, CGFloat(levels[i]) * h)
            l.frame = CGRect(x: CGFloat(i) * 5, y: (h - bh) / 2, width: 3, height: bh)
            l.opacity = frozen ? 0.5 : 1
        }
        CATransaction.commit()
    }

    override func layout() { super.layout(); if let last = bars.first { _ = last }; }
}
