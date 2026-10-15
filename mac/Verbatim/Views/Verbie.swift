import SwiftUI
import AppKit
import QuartzCore

enum VerbiePose: Equatable {
    case ready, listening, receiving, working, saved, paused, permission, interrupted, nothing

    /// Arm angles in degrees, from the prototype rig (verbie-rig.js).
    var armR: Double { switch self {
        case .ready: return 0; case .listening: return -150; case .receiving: return -95; case .working: return 85
        case .saved: return -165; case .paused: return 12; case .permission: return -110; case .interrupted: return -60; case .nothing: return -115 } }
    var armL: Double { switch self {
        case .ready: return 0; case .listening: return 8; case .receiving: return 95; case .working: return -75
        case .saved: return -15; case .paused: return -8; case .permission: return 5; case .interrupted: return 40; case .nothing: return 115 } }
    var barGrip: Double { switch self {
        case .receiving: return -50; case .working: return 95; case .interrupted: return -30; case .nothing: return -60; default: return 0 } }
    var handR: Double { switch self {
        case .listening: return -40; case .saved: return -50; case .permission: return 110; case .nothing: return 35; case .receiving: return 20; default: return 0 } }
    var lean: Double { switch self {
        case .listening: return -6; case .paused: return 7; case .permission: return 3; case .nothing: return -4; default: return 0 } }
}

/// Verbie in SwiftUI. The drawing and every animation live in Core Animation (VerbieLayerHost), so idle
/// motion costs the SwiftUI graph nothing: no body re-runs, no scene updates, no main-thread per-frame work.
struct VerbieView: NSViewRepresentable {
    var pose: VerbiePose = .ready
    var tracksPointer = true

    func makeNSView(context: Context) -> VerbieLayerHost {
        let v = VerbieLayerHost()
        v.tracksPointer = tracksPointer
        v.setPose(pose, animated: false)
        return v
    }
    func updateNSView(_ v: VerbieLayerHost, context: Context) {
        v.tracksPointer = tracksPointer
        v.setPose(pose, animated: true)
    }
}

// MARK: - Geometry shared with the prototype

enum ArmSide { case left, right }

enum ArmGeometry {
    /// Shoulder, two joints, hand. Pose angle splits 40/35/25 down the chain.
    static func joints(side: ArmSide, angle: Double) -> [CGPoint] {
        let (S, base, len): (CGPoint, [Double], [Double]) = side == .right
            ? (CGPoint(x: 142, y: 150), [62, 74, 84], [24, 24, 22])
            : (CGPoint(x: 58, y: 150), [118, 106, 96], [22, 21, 18])
        let split = [0.4, 0.75, 1.0]
        var pts = [S]; var x = S.x, y = S.y
        for i in 0..<3 {
            let t = (base[i] + angle * split[i]) * .pi / 180
            x += CGFloat(cos(t) * len[i]); y += CGFloat(sin(t) * len[i])
            pts.append(CGPoint(x: x, y: y))
        }
        return pts
    }

    /// Catmull-Rom through the four joints: one continuous rubber-hose stroke.
    static func hosePath(_ p: [CGPoint]) -> CGPath {
        let path = CGMutablePath(); path.move(to: p[0])
        for i in 0..<3 {
            let p0 = i == 0 ? p[0] : p[i - 1], p1 = p[i], p2 = p[i + 1], p3 = i + 2 < p.count ? p[i + 2] : p[i + 1]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

// MARK: - Core Animation rig

final class VerbieLayerHost: NSView {
    var tracksPointer = true
    private(set) var pose: VerbiePose = .ready

    private let root = CALayer()           // 200 × 300 design space, scaled to fit
    private let torso = CALayer()          // everything above the hips; the driver moves it (sway, lean, squash, hops)
    private let figure = CALayer()         // holds body, face, arms, props
    private let ground = CALayer()         // shadow, legs, and feet: never transformed, so feet stay planted
    private let legL = CAShapeLayer(), legR = CAShapeLayer()
    private let footL = CAShapeLayer(), footR = CAShapeLayer()
    private let shadowL = CAShapeLayer()
    private var rig = LegRig()
    private var link: Timer?
    private var lastTick: CFTimeInterval = 0
    private var frames = 0
    private let body = CALayer()           // breathes
    private let gaze = CALayer()           // eyes + mouth, drifts toward the pointer
    private let eyeL = CAShapeLayer(), eyeR = CAShapeLayer()
    private let happyL = CAShapeLayer(), happyR = CAShapeLayer(), shutL = CAShapeLayer(), shutR = CAShapeLayer()
    private let browL = CAShapeLayer(), browR = CAShapeLayer()
    private let mouth = CAShapeLayer(), grin = CAShapeLayer(), oh = CAShapeLayer()
    private let armR = CALayer(), armL = CALayer()     // sway about the shoulder
    private let hoseR = CAShapeLayer(), hoseL = CAShapeLayer()
    private let gloveR = CAShapeLayer(), gloveL = CAShapeLayer()
    private let bars = CALayer(), coral = CAShapeLayer(), lime = CAShapeLayer()
    private let mic = CALayer()
    private var props: [String: CALayer] = [:]
    private var monitor: Any?
    private var pointer: CGPoint?

    private static let iris = NSColor(red: 0x7C/255, green: 0x64/255, blue: 0xF3/255, alpha: 1).cgColor
    private static let deep = NSColor(red: 0x57/255, green: 0x42/255, blue: 0xD0/255, alpha: 1).cgColor
    private static let coralC = NSColor(red: 1, green: 0x7C/255, blue: 0x5C/255, alpha: 1).cgColor
    private static let limeC = NSColor(red: 0xB7/255, green: 0xE2/255, blue: 0x6A/255, alpha: 1).cgColor
    private static let ink = NSColor(red: 0x2A/255, green: 0x26/255, blue: 0x22/255, alpha: 1).cgColor

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        root.bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        root.anchorPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(root)
        buildLayers()
        applyRig()
        startIdle()
        layer?.setNeedsLayout()
    }

    override func layout() {
        super.layout()
        let s = min(bounds.width / 200, bounds.height / 300)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.position = CGPoint(x: bounds.midX, y: bounds.maxY)
        root.transform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()
        if window != nil { startLink() }
    }

    // MARK: Build

    private func shape(_ path: CGPath, fill: CGColor? = nil, stroke: CGColor? = nil, width: CGFloat = 0) -> CAShapeLayer {
        let l = CAShapeLayer(); l.path = path; l.fillColor = fill; l.strokeColor = stroke; l.lineWidth = width
        l.lineCap = .round; l.lineJoin = .round; return l
    }
    private func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }
    private func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> CGPath { let p = CGMutablePath(); p.move(to: a); p.addQuadCurve(to: b, control: c); return p }
    private func line(_ a: CGPoint, _ b: CGPoint) -> CGPath { let p = CGMutablePath(); p.move(to: a); p.addLine(to: b); return p }
    private func text(_ s: String, size: CGFloat, color: CGColor, at p: CGPoint) -> CATextLayer {
        let t = CATextLayer(); t.string = s; t.fontSize = size; t.font = NSFont.systemFont(ofSize: size, weight: .heavy)
        t.foregroundColor = color; t.alignmentMode = .left; t.contentsScale = 2; t.frame = CGRect(x: p.x, y: p.y, width: 60, height: size * 1.3); return t
    }

    private func buildLayers() {
        // Ground: shadow, legs, feet. Legs are solved with two-bone IK from the hips to planted feet every frame.
        ground.frame = root.bounds; root.addSublayer(ground)
        shadowL.path = CGPath(ellipseIn: CGRect(x: -48, y: -6, width: 96, height: 12), transform: nil)
        shadowL.fillColor = NSColor(red: 0x3A/255, green: 0x2D/255, blue: 0x1F/255, alpha: 0.14).cgColor
        shadowL.position = CGPoint(x: 100, y: LegRig.groundY + 6)
        ground.addSublayer(shadowL)
        for l in [legL, legR] { l.strokeColor = Self.deep; l.lineWidth = 6; l.fillColor = nil; l.lineCap = .round; l.lineJoin = .round; ground.addSublayer(l) }
        for f in [footL, footR] {
            f.path = CGPath(ellipseIn: CGRect(x: -13, y: -6, width: 26, height: 12), transform: nil); f.fillColor = Self.deep
            f.bounds = CGRect(x: -13, y: -6, width: 26, height: 12)
            ground.addSublayer(f)
        }

        torso.frame = root.bounds; root.addSublayer(torso)
        figure.frame = root.bounds; figure.anchorPoint = CGPoint(x: 0.5, y: 1); figure.position = CGPoint(x: 100, y: 300)
        torso.addSublayer(figure)

        // body: gradient capsule with a shaded corner and a highlight stroke; breathes about its base
        body.frame = CGRect(x: 55, y: 10, width: 90, height: 225)
        body.anchorPoint = CGPoint(x: 0.5, y: 1); body.position = CGPoint(x: 100, y: 235)
        let grad = CAGradientLayer(); grad.frame = body.bounds
        grad.colors = [NSColor(red: 0xAB/255, green: 0x9C/255, blue: 1, alpha: 1).cgColor, Self.iris, Self.deep]
        grad.locations = [0, 0.55, 1]; grad.startPoint = CGPoint(x: 0, y: 0); grad.endPoint = CGPoint(x: 1, y: 1)
        let mask = CAShapeLayer(); mask.path = CGPath(roundedRect: body.bounds, cornerWidth: 45, cornerHeight: 45, transform: nil); grad.mask = mask
        body.addSublayer(grad)
        let shade = CAGradientLayer(); shade.frame = body.bounds; shade.type = .radial
        shade.colors = [NSColor(red: 0x2D/255, green: 0x1D/255, blue: 0x7A/255, alpha: 0.28).cgColor, NSColor.clear.cgColor]
        shade.startPoint = CGPoint(x: 0.75, y: 0.85); shade.endPoint = CGPoint(x: 1.4, y: 1.5)
        let shadeMask = CAShapeLayer(); shadeMask.path = mask.path; shade.mask = shadeMask; body.addSublayer(shade)
        let hi = CAGradientLayer(); hi.frame = body.bounds; hi.type = .radial
        hi.colors = [NSColor.white.withAlphaComponent(0.5).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        hi.startPoint = CGPoint(x: 0.32, y: 0.18); hi.endPoint = CGPoint(x: 0.9, y: 0.75)
        let hiMask = CAShapeLayer(); hiMask.path = mask.path; hi.mask = hiMask; body.addSublayer(hi)
        let gloss = CGMutablePath(); gloss.move(to: CGPoint(x: 11, y: 52)); gloss.addCurve(to: CGPoint(x: 45, y: 6), control1: CGPoint(x: 11, y: 30), control2: CGPoint(x: 25, y: 12))
        body.addSublayer(shape(gloss, stroke: NSColor.white.withAlphaComponent(0.55).cgColor, width: 5))
        figure.addSublayer(body)

        // face
        gaze.frame = root.bounds; figure.addSublayer(gaze)
        for (eye, happy, shut, brow, cx) in [(eyeL, happyL, shutL, browL, 82.0), (eyeR, happyR, shutR, browR, 118.0)] {
            eye.path = circle(.zero, 5.5); eye.fillColor = NSColor.white.cgColor
            eye.bounds = CGRect(x: -6, y: -6, width: 12, height: 12); eye.position = CGPoint(x: cx, y: 80)
            gaze.addSublayer(eye)
            happy.path = quad(CGPoint(x: cx - 7, y: 83), CGPoint(x: cx, y: 74), CGPoint(x: cx + 7, y: 83)); happy.strokeColor = NSColor.white.cgColor; happy.lineWidth = 4; happy.fillColor = nil; happy.lineCap = .round; happy.opacity = 0
            shut.path = line(CGPoint(x: cx - 7, y: 81), CGPoint(x: cx + 7, y: 81)); shut.strokeColor = NSColor.white.cgColor; shut.lineWidth = 4; shut.fillColor = nil; shut.lineCap = .round; shut.opacity = 0
            brow.bounds = CGRect(x: cx - 12, y: 56, width: 24, height: 16); brow.position = CGPoint(x: cx, y: 64)
            brow.path = quad(CGPoint(x: cx - 8, y: 66), CGPoint(x: cx, y: 61), CGPoint(x: cx + 8, y: 66)); brow.strokeColor = NSColor.white.cgColor; brow.lineWidth = 4; brow.fillColor = nil; brow.lineCap = .round; brow.opacity = 0
            gaze.addSublayer(happy); gaze.addSublayer(shut); gaze.addSublayer(brow)
        }
        mouth.path = quad(CGPoint(x: 87, y: 100), CGPoint(x: 100, y: 112), CGPoint(x: 113, y: 100)); mouth.strokeColor = NSColor.white.cgColor; mouth.lineWidth = 4; mouth.fillColor = nil; mouth.lineCap = .round
        let g = CGMutablePath(); g.move(to: CGPoint(x: 84, y: 98)); g.addQuadCurve(to: CGPoint(x: 116, y: 98), control: CGPoint(x: 100, y: 120)); g.closeSubpath()
        grin.path = g; grin.fillColor = NSColor.white.cgColor; grin.opacity = 0
        oh.path = circle(CGPoint(x: 100, y: 103), 6); oh.strokeColor = NSColor.white.cgColor; oh.lineWidth = 4; oh.fillColor = nil; oh.opacity = 0
        gaze.addSublayer(mouth); gaze.addSublayer(grin); gaze.addSublayer(oh)

        // arms: a group anchored at the shoulder (so idle sway rotates the whole arm), hose + glove inside
        for (arm, hose, glove, shoulder) in [(armR, hoseR, gloveR, CGPoint(x: 142, y: 150)), (armL, hoseL, gloveL, CGPoint(x: 58, y: 150))] {
            arm.bounds = root.bounds; arm.anchorPoint = CGPoint(x: shoulder.x / 200, y: shoulder.y / 300); arm.position = shoulder
            hose.strokeColor = Self.deep; hose.lineWidth = 7; hose.fillColor = nil; hose.lineCap = .round; hose.lineJoin = .round
            glove.fillColor = NSColor.white.cgColor; glove.strokeColor = Self.deep; glove.lineWidth = 2.5
            arm.addSublayer(hose)
            if arm === armL {
                bars.bounds = CGRect(x: -30, y: -60, width: 70, height: 100); bars.anchorPoint = CGPoint(x: 30.0 / 70.0, y: 60.0 / 100.0)
                coral.path = CGPath(roundedRect: CGRect(x: -20, y: -48, width: 30, height: 78), cornerWidth: 15, cornerHeight: 15, transform: nil); coral.fillColor = Self.coralC
                coral.transform = CATransform3DMakeRotation(-8 * .pi / 180, 0, 0, 1)
                lime.path = CGPath(roundedRect: CGRect(x: -1, y: -36, width: 26, height: 58), cornerWidth: 13, cornerHeight: 13, transform: nil); lime.fillColor = Self.limeC
                lime.transform = CATransform3DMakeRotation(-8 * .pi / 180, 0, 0, 1)
                bars.addSublayer(coral); bars.addSublayer(lime); arm.addSublayer(bars)
            }
            arm.addSublayer(glove)
            if arm === armR {
                mic.bounds = CGRect(x: -20, y: -40, width: 40, height: 50); mic.anchorPoint = CGPoint(x: 0.5, y: 0.8)
                let cap = shape(CGPath(roundedRect: CGRect(x: -8, y: -32, width: 16, height: 30), cornerWidth: 8, cornerHeight: 8, transform: nil), fill: Self.ink)
                let arc = CGMutablePath(); arc.addArc(center: CGPoint(x: 0, y: -14), radius: 14, startAngle: 0, endAngle: .pi, clockwise: false); arc.move(to: CGPoint(x: 0, y: 0)); arc.addLine(to: CGPoint(x: 0, y: 8))
                mic.addSublayer(cap); mic.addSublayer(shape(arc, stroke: Self.ink, width: 4)); mic.opacity = 0
                arm.addSublayer(mic)
            }
            figure.addSublayer(arm)
        }

        // props (hidden until a pose needs them)
        let wave = CGMutablePath()
        wave.addArc(center: CGPoint(x: 172, y: 84), radius: 18, startAngle: -.pi / 3, endAngle: .pi / 3, clockwise: false)
        wave.move(to: CGPoint(x: 172 + 34 * cos(-Double.pi / 3), y: 84 + 34 * sin(-Double.pi / 3)))
        wave.addArc(center: CGPoint(x: 172, y: 84), radius: 34, startAngle: -.pi / 3, endAngle: .pi / 3, clockwise: false)
        props["waves"] = shape(wave, stroke: Self.coralC, width: 5)
        props["zzz"] = text("z z z", size: 24, color: Self.iris, at: CGPoint(x: 146, y: 8))
        props["bang"] = text("!", size: 52, color: Self.coralC, at: CGPoint(x: 150, y: -6))
        props["q"] = text("?", size: 52, color: Self.iris, at: CGPoint(x: 146, y: -6))
        let check = CALayer(); check.frame = CGRect(x: 148, y: 22, width: 36, height: 36)
        check.addSublayer(shape(circle(CGPoint(x: 18, y: 18), 18), fill: Self.limeC))
        let ck = CGMutablePath(); ck.move(to: CGPoint(x: 9, y: 19)); ck.addLine(to: CGPoint(x: 16, y: 26)); ck.addLine(to: CGPoint(x: 28, y: 12))
        check.addSublayer(shape(ck, stroke: NSColor(red: 0x1F/255, green: 0x3A/255, blue: 0x0A/255, alpha: 1).cgColor, width: 4.5))
        props["check"] = check
        let dots = CALayer(); dots.frame = CGRect(x: 154, y: 100, width: 50, height: 24)
        for i in 0..<3 { let d = shape(circle(CGPoint(x: 6 + CGFloat(i) * 18, y: 12), 6), fill: Self.iris); d.opacity = Float(1 - Double(i) * 0.25); dots.addSublayer(d) }
        props["dots"] = dots
        for (_, l) in props { l.opacity = 0; figure.addSublayer(l) }
    }

    // MARK: Poses

    func setPose(_ p: VerbiePose, animated: Bool) {
        let changed = p != pose
        guard changed || !animated else { return }   // SwiftUI re-renders must not restart the pose animation
        pose = p
        let dur: CFTimeInterval = animated ? 0.45 : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(dur)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.3, 1.3, 0.5, 1))

        // arms: hose path + glove position; bars rotate about the glove
        let jR = ArmGeometry.joints(side: .right, angle: p.armR), jL = ArmGeometry.joints(side: .left, angle: p.armL)
        hoseR.path = ArmGeometry.hosePath(jR); hoseL.path = ArmGeometry.hosePath(jL)
        gloveR.path = circle(jR[3], 10); gloveL.path = circle(jL[3], 10)
        bars.position = jL[3]
        bars.transform = CATransform3DMakeRotation((p.armL + p.barGrip) * .pi / 180, 0, 0, 1)
        mic.position = jR[3]
        mic.transform = CATransform3DMakeRotation((p.armR + p.handR) * .pi / 180, 0, 0, 1)
        mic.opacity = p == .permission ? 1 : 0

        // face
        let happy = p == .saved, shut = p == .paused, narrow = p == .working, wide = p == .interrupted || p == .receiving
        for e in [eyeL, eyeR] { e.opacity = happy || shut ? 0 : 1; e.transform = CATransform3DMakeScale(wide ? 1.4 : 1, narrow ? 0.55 : wide ? 1.4 : 1, 1) }
        for h in [happyL, happyR] { h.opacity = happy ? 1 : 0 }
        for s in [shutL, shutR] { s.opacity = shut ? 1 : 0 }
        let browsOn = !(p == .ready || p == .paused || p == .saved)
        let browY: CGFloat = wide ? -6 : narrow ? 2 : -3
        for (b, sign) in [(browL, -1.0), (browR, 1.0)] {
            b.opacity = browsOn ? 1 : 0
            let tilt = (p == .working ? 12.0 : p == .nothing ? -14.0 : 0) * sign * .pi / 180
            b.transform = CATransform3DConcat(CATransform3DMakeRotation(tilt, 0, 0, 1), CATransform3DMakeTranslation(0, browY, 0))
        }
        switch p {
        case .saved, .receiving: mouth.opacity = 0; grin.opacity = 1; oh.opacity = 0
        case .working, .paused: mouth.path = line(CGPoint(x: 90, y: 102), CGPoint(x: 110, y: 102)); mouth.opacity = 1; grin.opacity = 0; oh.opacity = 0
        case .interrupted, .listening: mouth.opacity = 0; grin.opacity = 0; oh.opacity = 1
        case .nothing:
            let w = CGMutablePath(); w.move(to: CGPoint(x: 88, y: 102)); w.addQuadCurve(to: CGPoint(x: 100, y: 102), control: CGPoint(x: 94, y: 95)); w.addQuadCurve(to: CGPoint(x: 112, y: 102), control: CGPoint(x: 106, y: 109))
            mouth.path = w; mouth.opacity = 1; grin.opacity = 0; oh.opacity = 0
        default: mouth.path = quad(CGPoint(x: 87, y: 100), CGPoint(x: 100, y: 112), CGPoint(x: 113, y: 100)); mouth.opacity = 1; grin.opacity = 0; oh.opacity = 0
        }

        // lean and props
        rig.leanTarget = p.lean
        if link == nil { rig.lean = p.lean; applyRig() }
        let show: String? = { switch p { case .listening: return "waves"; case .paused: return "zzz"; case .saved: return "check"; case .interrupted: return "bang"; case .nothing: return "q"; case .working: return "dots"; default: return nil } }()
        for (k, l) in props { l.opacity = k == show ? 1 : 0; l.transform = k == show ? CATransform3DIdentity : CATransform3DMakeScale(0.6, 0.6, 1) }
        CATransaction.commit()

        if changed && animated && link != nil { rig.react(to: p, at: CACurrentMediaTime()) }
    }

    // MARK: Legs and weight (procedural, inverse kinematics)

    /// Places the torso and solves both legs for the current rig state. No implicit animations.
    private func applyRig() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let pose = rig.torsoTransform()
        torso.transform = pose.layer
        for (leg, foot, side) in [(legL, footL, 0), (legR, footR, 1)] {
            let hip = pose.apply(LegRig.hipRest[side])
            let f = rig.feet[side]
            let ankle = CGPoint(x: f.x, y: f.y - 10)
            let (a, knee) = LegRig.solve(hip: hip, ankle: ankle, bendOut: side == 0 ? -1 : 1)
            let path = CGMutablePath(); path.move(to: hip)
            // Rubber hose: one smooth curve that passes through the knee.
            let ctrl = CGPoint(x: 2 * knee.x - (hip.x + a.x) / 2, y: 2 * knee.y - (hip.y + a.y) / 2)
            path.addQuadCurve(to: a, control: ctrl)
            leg.path = path
            foot.position = CGPoint(x: a.x + (side == 0 ? -3 : 3), y: a.y + 4)
            foot.transform = CATransform3DMakeRotation(rig.footTilt[side] * (side == 0 ? 1 : -1), 0, 0, 1)
        }
        // The shadow tightens and fades when he leaves the ground.
        let lift = max(0, LegRig.groundY - max(rig.feet[0].y, rig.feet[1].y))
        let k = max(0.6, 1 - lift / 40)
        shadowL.position = CGPoint(x: 100 + (rig.feet[0].x + rig.feet[1].x - 200) / 2 + pose.dx * 0.5, y: LegRig.groundY + 6)
        shadowL.transform = CATransform3DMakeScale(k, k, 1)
        shadowL.opacity = Float(k)
        CATransaction.commit()
    }

    private func startLink() {
        guard link == nil, bounds.height >= 50 else { return }
        // The self-test runs the rig even if the runner has Reduce Motion on, so CI exercises it.
        if reduceMotion && !UITest.enabled { return }
        // A 30 Hz timer rather than a display link: display links don't fire on some virtual displays,
        // and 30 Hz is plenty for a character this size.
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.005
        RunLoop.main.add(t, forMode: .common)
        link = t; lastTick = 0
        if UITest.enabled { Log.note("UITEST verbie rig started (\(Int(bounds.width))×\(Int(bounds.height)) pt)") }
    }

    private func stopLink() { link?.invalidate(); link = nil }

    private func tick() {
        guard let w = window, w.occlusionState.contains(.visible) || UITest.enabled, !isHiddenOrHasHiddenAncestor else { lastTick = 0; return }
        let now = CACurrentMediaTime()
        let dt = lastTick == 0 ? 1.0 / 30 : min(0.1, now - lastTick)
        lastTick = now
        rig.advance(now: now, dt: dt, pose: pose)
        applyRig()
        frames += 1
        if UITest.enabled, frames % 150 == 0, frames <= 600 { Log.note(String(format: "UITEST verbie feet %.1f/%.1f hips dx %.1f dy %.1f", rig.feet[0].x, rig.feet[1].x, rig.dx, rig.dy)) }
        if frames == 90, UITest.enabled { Log.note("UITEST verbie rig ticking (\(Int(bounds.width))×\(Int(bounds.height)) pt)") }
    }

    // MARK: Idle (render-server driven; nothing touches SwiftUI)

    private func startIdle() {
        guard !reduceMotion else { return }
        let breathe = CABasicAnimation(keyPath: "transform.scale.y")
        breathe.fromValue = 1; breathe.toValue = 1.025; breathe.duration = 1.9; breathe.autoreverses = true; breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        body.add(breathe, forKey: "breathe")

        for (arm, amp, period, phase) in [(armR, 2.5, 3.6, 0.0), (armL, 2.2, 4.1, 1.1)] {
            let sway = CABasicAnimation(keyPath: "transform.rotation.z")
            sway.fromValue = -amp * .pi / 180; sway.toValue = amp * .pi / 180; sway.duration = period; sway.autoreverses = true; sway.repeatCount = .infinity
            sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); sway.timeOffset = phase
            arm.add(sway, forKey: "sway")
        }

        // Blink every ~5.5 s (sources: 5–10 s between blinks), both eyes together, random start offset.
        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        blink.values = [1, 1, 0.08, 1]; blink.keyTimes = [0, 0.95, 0.97, 1]; blink.duration = 5.5; blink.repeatCount = .infinity
        blink.isAdditive = false; blink.timeOffset = Double.random(in: 0..<5)
        eyeL.add(blink, forKey: "blink"); eyeR.add(blink, forKey: "blink")
    }

    // MARK: Pointer tracking: eyes and mouth drift up to 5 pt toward the pointer, body leans 3°

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopLink() } else { DispatchQueue.main.async { [weak self] in self?.startLink() } }
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard window != nil, tracksPointer, !reduceMotion else { return }
        window?.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            self?.track(e); return e
        }
    }

    private func track(_ e: NSEvent) {
        guard let w = window, e.window === w, pose == .ready || pose == .listening || pose == .working else { return }
        let p = convert(e.locationInWindow, from: nil)
        let c = CGPoint(x: bounds.midX, y: bounds.midY * 0.6)
        let dx = max(-1, min(1, (p.x - c.x) / 300)), dy = max(-1, min(1, (p.y - c.y) / 300))
        CATransaction.begin(); CATransaction.setAnimationDuration(0.12)
        gaze.transform = CATransform3DMakeTranslation(dx * 5, dy * 4, 0)
        if pose == .ready { rig.pointerLean = dx * 3 }
        CATransaction.commit()
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) }; link?.invalidate() }
}

// MARK: - Leg rig

/// Verbie's lower body: two feet that stay planted on the ground line, hips that sway and dip with his weight,
/// and two-bone IK legs between them. Idle: weight shifts side to side, and every few seconds he moves a foot
/// (lift, arc, plant) toward where his weight has gone. Pose changes add a squash, a hop, or a startle.
struct LegRig {
    static let groundY: CGFloat = 280
    static let hipRest = [CGPoint(x: 86, y: 230), CGPoint(x: 114, y: 230)]
    static let homeX: [CGFloat] = [82, 118]
    static let thigh: CGFloat = 20.8, shin: CGFloat = 20.8

    struct Foot { var x: CGFloat; var y: CGFloat }
    struct Step { var side: Int; var fromX: CGFloat; var toX: CGFloat; var start: Double; var duration: Double; var height: CGFloat }

    var feet = [Foot(x: 82, y: groundY), Foot(x: 118, y: groundY)]
    var footTilt: [Double] = [0, 0]
    var lean: Double = 0, leanTarget: Double = 0, pointerLean: Double = 0
    var dx: CGFloat = 0, dy: CGFloat = 0           // pelvis offset (weight)
    var squash: CGFloat = 1                         // y scale of the torso about the hips
    var weight: CGFloat = 0                         // -1 on the left foot … +1 on the right
    var step: Step?
    var nextStepAt: Double = 0
    var hop: (start: Double, height: CGFloat, duration: Double)?
    var pop: Double = -10
    var clock: Double = 0
    var seed: UInt64 = UInt64.random(in: 1...UInt64.max)

    mutating func rand() -> Double { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return Double(seed % 10_000) / 10_000 }

    /// Two-bone IK in the plane: returns the reachable ankle and the knee, bending outward.
    static func solve(hip: CGPoint, ankle: CGPoint, bendOut: CGFloat) -> (CGPoint, CGPoint) {
        var vx = ankle.x - hip.x, vy = ankle.y - hip.y
        var d = max(0.001, hypot(vx, vy))
        let reach = thigh + shin - 0.5
        var a = ankle
        if d > reach { vx *= reach / d; vy *= reach / d; d = reach; a = CGPoint(x: hip.x + vx, y: hip.y + vy) }
        let along = (thigh * thigh - shin * shin + d * d) / (2 * d)
        let h = sqrt(max(0, thigh * thigh - along * along))
        let ux = vx / d, uy = vy / d
        // perpendicular pointing outward from the body
        var px = -uy, py = ux
        if px * bendOut < 0 { px = -px; py = -py }
        return (a, CGPoint(x: hip.x + ux * along + px * h, y: hip.y + uy * along + py * h))
    }

    struct TorsoPose {
        var dx: CGFloat, dy: CGFloat, angle: CGFloat, sy: CGFloat
        /// Rotate about the hips' midpoint, squash about it, then translate.
        var layer: CATransform3D {
            let c = CGPoint(x: 100, y: 230)
            var t = CATransform3DMakeTranslation(dx, dy, 0)
            t = CATransform3DTranslate(t, c.x, c.y, 0)
            t = CATransform3DRotate(t, angle, 0, 0, 1)
            t = CATransform3DScale(t, 2 - sy, sy, 1)
            t = CATransform3DTranslate(t, -c.x, -c.y, 0)
            return t
        }
        func apply(_ p: CGPoint) -> CGPoint {
            let c = CGPoint(x: 100, y: 230)
            let x = (p.x - c.x) * (2 - sy), y = (p.y - c.y) * sy
            let ca = cos(angle), sa = sin(angle)
            return CGPoint(x: c.x + x * ca - y * sa + dx, y: c.y + x * sa + y * ca + dy)
        }
    }

    func torsoTransform() -> TorsoPose {
        TorsoPose(dx: dx, dy: dy, angle: CGFloat((lean + pointerLean) * .pi / 180) + dx * 0.004, sy: squash)
    }

    mutating func react(to p: VerbiePose, at now: Double) {
        pop = now
        switch p {
        case .saved: hop = (now + 0.08, 22, 0.5)
        case .interrupted: hop = (now, 9, 0.28); queueStep(now: now + 0.3, side: rand() < 0.5 ? 0 : 1, outward: 4)
        case .receiving: queueStep(now: now + 0.1, side: 1, outward: 2)
        case .nothing: queueStep(now: now + 0.15, side: 0, outward: -2)
        default: break
        }
    }

    private mutating func queueStep(now: Double, side: Int, outward: CGFloat) {
        guard step == nil else { return }
        let to = Self.homeX[side] + (side == 0 ? -outward : outward)
        step = Step(side: side, fromX: feet[side].x, toX: to, start: now, duration: 0.32, height: 9)
    }

    mutating func advance(now: Double, dt: Double, pose: VerbiePose) {
        clock = now
        if nextStepAt == 0 { nextStepAt = now + 2 + rand() * 4 }
        let calm = pose == .paused
        // Weight drifts side to side on a slow, uneven rhythm.
        let sway = sin(now * (calm ? 0.5 : 0.9)) * 0.7 + sin(now * 0.37 + 1.3) * 0.3
        var targetWeight = CGFloat(sway)
        if let s = step { targetWeight = s.side == 0 ? 1 : -1 }            // stand on the other foot while one moves
        weight += (targetWeight - weight) * CGFloat(min(1, dt * 3))
        let leftX = feet[0].x, rightX = feet[1].x
        let overX = (leftX + rightX) / 2 - 100 + weight * (rightX - leftX) * 0.18
        dx += (overX - dx) * CGFloat(min(1, dt * 4))
        // The hips dip as weight passes between the feet, and sink a little when he dozes.
        var targetDy: CGFloat = (1 - abs(weight)) * 1.6 + (calm ? 3 : 0)
        if let h = hop {
            let u = (now - h.start) / h.duration
            if u >= 1 { hop = nil; pop = now }
            else if u > 0 {
                // Crouch, launch, fall: a quick anticipation dip before the arc.
                targetDy = u < 0.18 ? 6 * CGFloat(u / 0.18) : -h.height * CGFloat(sin(.pi * (u - 0.18) / 0.82))
                dy = targetDy
            }
        }
        if hop == nil { dy += (targetDy - dy) * CGFloat(min(1, dt * 8)) }
        lean += (leanTarget - lean) * min(1, dt * 7)

        // Squash and stretch after a pose change or a landing.
        let pu = now - pop
        squash = pu < 0.5 ? 1 - CGFloat(0.06 * sin(pu / 0.5 * .pi * 2) * exp(-pu * 5)) : 1

        // Steps: start one when it's time, or when the weight has drifted far from the feet.
        if step == nil, hop == nil, !calm, now >= nextStepAt {
            let side = weight > 0 ? 0 : 1                               // move the unweighted foot
            let drift = (dx - ((feet[0].x + feet[1].x) / 2 - 100))
            // A visible move: 4–9 pt in or out from where the foot is, kept within a comfortable stance.
            let dir: CGFloat = feet[side].x > Self.homeX[side] ? -1 : feet[side].x < Self.homeX[side] ? 1 : (rand() < 0.5 ? -1 : 1)
            var to = feet[side].x + dir * CGFloat(4 + rand() * 5) + drift * 0.4
            to = min(max(to, Self.homeX[side] - 10), Self.homeX[side] + 10)
            step = Step(side: side, fromX: feet[side].x, toX: to, start: now, duration: 0.3 + rand() * 0.12, height: 8 + CGFloat(rand() * 5))
            // Sometimes the other foot follows: a little shuffle.
            nextStepAt = now + (rand() < 0.3 ? 0.55 : 3.5 + rand() * 5)
        }
        if let s = step, now >= s.start {
            let u = min(1, (now - s.start) / s.duration)
            let e = CGFloat(u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2)
            feet[s.side].x = s.fromX + (s.toX - s.fromX) * e
            feet[s.side].y = Self.groundY - s.height * CGFloat(sin(.pi * u))
            footTilt[s.side] = -0.25 * sin(.pi * u)
            if u >= 1 { feet[s.side].y = Self.groundY; footTilt[s.side] = 0; step = nil }
        }
        // In the air, feet hang from the hips (IK clamps reach); back on the ground they plant again.
        if hop != nil, dy < -2 {
            let tp = torsoTransform()
            for i in 0..<2 where step?.side != i {
                let hip = tp.apply(Self.hipRest[i])
                feet[i].y = min(Self.groundY, hip.y + Self.thigh + Self.shin + 8)
                footTilt[i] = 0.12 * (i == 0 ? 1 : -1)
            }
        } else {
            for i in 0..<2 where step?.side != i { feet[i].y += (Self.groundY - feet[i].y) * CGFloat(min(1, dt * 20)); footTilt[i] *= 0.8 }
        }
    }
}
