import SwiftUI
import Combine

import AppKit
import QuartzCore

/// Live audio meter drawn with Core Animation bars. Heights arrive from the recorder a few times a
/// second; the render server interpolates between them, so SwiftUI never runs per frame.
/// Elapsed time + bars, observing only the LiveMeter so the rest of the app stays still while recording.
struct LiveReadout: View {
    @ObservedObject var live: LiveMeter
    var color: NSColor = NSColor(hex: Ink.persimmonHex)
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
    var color: NSColor = NSColor(hex: Ink.persimmonHex)
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
