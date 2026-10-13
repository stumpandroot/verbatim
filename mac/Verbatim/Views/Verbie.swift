import SwiftUI

enum VerbiePose: Equatable {
    case ready, listening, receiving, working, saved, paused, permission, interrupted, nothing

    /// Arm angles in degrees, mirrored from the prototype rig (verbie-rig.js).
    var armR: Double { switch self {
        case .ready: return 0; case .listening: return -150; case .receiving: return -95; case .working: return 85
        case .saved: return -165; case .paused: return 12; case .permission: return -110; case .interrupted: return -60; case .nothing: return -115 } }
    var armL: Double { switch self {
        case .ready: return 0; case .listening: return 8; case .receiving: return 95; case .working: return -75
        case .saved: return -15; case .paused: return -8; case .permission: return 5; case .interrupted: return 40; case .nothing: return 115 } }
    var barGrip: Double { switch self {
        case .receiving: return -50; case .working: return 95; case .interrupted: return -30; case .nothing: return -60; default: return 0 } }
    var lean: Double { switch self {
        case .listening: return -6; case .paused: return 7; case .permission: return 3; case .nothing: return -4; default: return 0 } }
}

/// Verbie: the capsule from the Verbatim wordmark, holding the coral and lime bars.
/// Drawn in a 200 × 300 design space and scaled to fit.
struct VerbieView: View {
    var pose: VerbiePose = .ready
    @State private var pop = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // No continuous idle animation on purpose: on macOS 26 every SwiftUI transaction rebuilds the
    // scene (menus, toolbar, menu bar item), so a 30 fps idle loop pins the main thread. Verbie
    // moves on pose changes and holds still otherwise. A Core Animation rig can bring idle back.
    var body: some View {
        VerbieFigure(pose: pose, swayR: 0, swayL: 0, breathe: 1, blink: false, pop: pop)
            .onChange(of: pose) { _, _ in
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.12)) { pop = true }
                withAnimation(Motion.bounce.delay(0.12)) { pop = false }
            }
    }
}

/// The figure itself. Pose changes animate on the Bounce spring; idle motion comes in as plain values.
struct VerbieFigure: View {
    var pose: VerbiePose
    var swayR: Double
    var swayL: Double
    var breathe: Double
    var blink: Bool
    var pop: Bool

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width / 200, g.size.height / 300)
            ZStack(alignment: .topLeading) {
                shadow
                legs
                body3D
                face
                ArmView(side: .right, angle: pose.armR + swayR, grip: 0, pose: pose)
                ArmView(side: .left, angle: pose.armL + swayL, grip: pose.barGrip, pose: pose)
                props
            }
            .frame(width: 200, height: 300)
            .scaleEffect(x: pop ? 1.06 : 1, y: pop ? 0.94 : 1, anchor: .bottom)
            .scaleEffect(x: 1, y: breathe, anchor: .bottom)
            .rotationEffect(.degrees(pose.lean), anchor: .bottom)
            .scaleEffect(s, anchor: .center)
            .frame(width: 200 * s, height: 300 * s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .drawingGroup()
        .animation(Motion.bounce, value: pose)
    }

    private var shadow: some View {
        Ellipse().fill(Color(hex: 0x3A2D1F).opacity(0.14)).frame(width: 96, height: 12).offset(x: 52, y: 281)
    }

    private var legs: some View {
        ZStack(alignment: .topLeading) {
            Path { p in p.move(to: CGPoint(x: 86, y: 230)); p.addQuadCurve(to: CGPoint(x: 84, y: 270), control: CGPoint(x: 82, y: 250)) }
                .stroke(Ink.irisDeep, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            Path { p in p.move(to: CGPoint(x: 114, y: 230)); p.addQuadCurve(to: CGPoint(x: 116, y: 270), control: CGPoint(x: 118, y: 250)) }
                .stroke(Ink.irisDeep, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            Ellipse().fill(Ink.irisDeep).frame(width: 26, height: 12).offset(x: 69, y: 268)
            Ellipse().fill(Ink.irisDeep).frame(width: 26, height: 12).offset(x: 105, y: 268)
        }
    }

    private var body3D: some View {
        let capsule = RoundedRectangle(cornerRadius: 45, style: .continuous)
        return ZStack(alignment: .topLeading) {
            capsule.fill(LinearGradient(colors: [Color(hex: 0xAB9CFF), Color(hex: 0x7C64F3), Ink.irisDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
            capsule.fill(RadialGradient(colors: [Color(hex: 0x2D1D7A).opacity(0.28), .clear], center: UnitPoint(x: 0.75, y: 0.85), startRadius: 0, endRadius: 140))
            capsule.fill(RadialGradient(colors: [.white.opacity(0.5), .clear], center: UnitPoint(x: 0.32, y: 0.18), startRadius: 0, endRadius: 120))
            Path { p in p.move(to: CGPoint(x: 11, y: 52)); p.addCurve(to: CGPoint(x: 45, y: 6), control1: CGPoint(x: 11, y: 30), control2: CGPoint(x: 25, y: 12)) }
                .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }
        .frame(width: 90, height: 225)
        .offset(x: 55, y: 10)
    }

    private var face: some View {
        let happy = pose == .saved
        let shut = pose == .paused
        let narrow = pose == .working
        let wide = pose == .interrupted || pose == .receiving
        return ZStack(alignment: .topLeading) {
            // eyebrows
            Path { p in
                p.move(to: CGPoint(x: 74, y: 66)); p.addQuadCurve(to: CGPoint(x: 90, y: 66), control: CGPoint(x: 82, y: 61))
                p.move(to: CGPoint(x: 110, y: 66)); p.addQuadCurve(to: CGPoint(x: 126, y: 66), control: CGPoint(x: 118, y: 61))
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .opacity(pose == .ready || pose == .paused || pose == .saved ? 0 : 1)
            .offset(y: wide ? -6 : narrow ? 2 : -3)
            // eyes
            ForEach([82.0, 118.0], id: \.self) { x in
                ZStack(alignment: .topLeading) {
                    Circle().fill(.white).frame(width: 11, height: 11)
                        .scaleEffect(x: wide ? 1.4 : 1, y: blink || narrow ? 0.12 : wide ? 1.4 : 1)
                        .opacity(happy || shut ? 0 : 1)
                    Path { p in p.move(to: CGPoint(x: -1.5, y: 8.5)); p.addQuadCurve(to: CGPoint(x: 12.5, y: 8.5), control: CGPoint(x: 5.5, y: -1)) }
                        .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round)).opacity(happy ? 1 : 0)
                    Path { p in p.move(to: CGPoint(x: -1.5, y: 6)); p.addLine(to: CGPoint(x: 12.5, y: 6)) }
                        .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round)).opacity(shut ? 1 : 0)
                }
                .frame(width: 11, height: 11)
                .offset(x: x - 5.5, y: 74.5)
            }
            // mouth
            mouth
        }
    }

    @ViewBuilder private var mouth: some View {
        switch pose {
        case .ready, .permission, .listening:
            Path { p in p.move(to: CGPoint(x: 87, y: 100)); p.addQuadCurve(to: CGPoint(x: 113, y: 100), control: CGPoint(x: 100, y: 112)) }
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        case .saved, .receiving:
            Path { p in p.move(to: CGPoint(x: 84, y: 98)); p.addQuadCurve(to: CGPoint(x: 116, y: 98), control: CGPoint(x: 100, y: 120)); p.closeSubpath() }
                .fill(.white)
        case .working, .paused:
            Path { p in p.move(to: CGPoint(x: 90, y: 102)); p.addLine(to: CGPoint(x: 110, y: 102)) }
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        case .interrupted:
            Circle().stroke(.white, lineWidth: 4).frame(width: 12, height: 12).offset(x: 94, y: 97)
        case .nothing:
            Path { p in p.move(to: CGPoint(x: 88, y: 102)); p.addQuadCurve(to: CGPoint(x: 100, y: 102), control: CGPoint(x: 94, y: 95)); p.addQuadCurve(to: CGPoint(x: 112, y: 102), control: CGPoint(x: 106, y: 109)) }
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
    }

    @ViewBuilder private var props: some View {
        switch pose {
        case .listening:
            Path { p in
                p.addArc(center: CGPoint(x: 172, y: 84), radius: 18, startAngle: .degrees(-60), endAngle: .degrees(60), clockwise: false)
                p.move(to: CGPoint(x: 172 + 34 * cos(-Double.pi / 3), y: 84 + 34 * sin(-Double.pi / 3)))
                p.addArc(center: CGPoint(x: 172, y: 84), radius: 34, startAngle: .degrees(-60), endAngle: .degrees(60), clockwise: false)
            }.stroke(Ink.coral, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            .transition(.scale.combined(with: .opacity))
        case .paused:
            Text("z z z").font(.system(size: 26, weight: .heavy)).foregroundStyle(Color(hex: 0x7C64F3)).offset(x: 146, y: 6)
                .transition(.scale.combined(with: .opacity))
        case .saved:
            ZStack { Circle().fill(Ink.lime).frame(width: 36, height: 36); Image(systemName: "checkmark").font(.system(size: 20, weight: .bold)).foregroundStyle(Ink.limeDeep) }
                .offset(x: 148, y: 22).transition(.scale.combined(with: .opacity))
        case .interrupted:
            Text("!").font(.system(size: 56, weight: .heavy)).foregroundStyle(Ink.coral).offset(x: 150, y: -4).transition(.scale.combined(with: .opacity))
        case .nothing:
            Text("?").font(.system(size: 56, weight: .heavy)).foregroundStyle(Color(hex: 0x7C64F3)).offset(x: 148, y: -4).transition(.scale.combined(with: .opacity))
        case .working:
            WorkingDots().offset(x: 154, y: 106).transition(.scale.combined(with: .opacity))
        case .permission:
            EmptyView()
        default:
            EmptyView()
        }
    }
}

private struct WorkingDots: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle().fill(Color(hex: 0x7C64F3)).frame(width: 12, height: 12).opacity(1 - Double(i) * 0.25)
            }
        }
    }
}

// MARK: - Rubber-hose arm

enum ArmSide { case left, right }

/// Forward kinematics shared by the stroke, the glove, and the bars, so they animate together.
struct ArmGeometry {
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
}

struct HoseShape: Shape {
    var side: ArmSide
    var angle: Double
    var animatableData: Double { get { angle } set { angle = newValue } }
    func path(in rect: CGRect) -> Path {
        let p = ArmGeometry.joints(side: side, angle: angle)
        var path = Path(); path.move(to: p[0])
        for i in 0..<3 {
            let p0 = i == 0 ? p[0] : p[i - 1], p1 = p[i], p2 = p[i + 1], p3 = i + 2 < p.count ? p[i + 2] : p[i + 1]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

struct GloveShape: Shape {
    var side: ArmSide
    var angle: Double
    var animatableData: Double { get { angle } set { angle = newValue } }
    func path(in rect: CGRect) -> Path {
        let h = ArmGeometry.joints(side: side, angle: angle)[3]
        return Path(ellipseIn: CGRect(x: h.x - 10, y: h.y - 10, width: 20, height: 20))
    }
}

/// The coral or lime bar, hanging from the left glove and rotating with it.
struct BarShape: Shape {
    var lime: Bool
    var angle: Double
    var grip: Double
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(angle, grip) }
        set { angle = newValue.first; grip = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let h = ArmGeometry.joints(side: .left, angle: angle)[3]
        let rot = (angle + grip - 8) * .pi / 180
        let r = lime ? CGRect(x: -1, y: -36, width: 26, height: 58) : CGRect(x: -20, y: -48, width: 30, height: 78)
        let t = CGAffineTransform(translationX: h.x, y: h.y).rotated(by: rot)
        return Path(roundedRect: r, cornerRadius: r.width / 2).applying(t)
    }
}

struct ArmView: View {
    var side: ArmSide
    var angle: Double
    var grip: Double
    var pose: VerbiePose
    var body: some View {
        ZStack(alignment: .topLeading) {
            HoseShape(side: side, angle: angle).stroke(Ink.irisDeep, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            if side == .left {
                BarShape(lime: false, angle: angle, grip: grip).fill(LinearGradient(colors: [Color(hex: 0xFFA184), Color(hex: 0xEF6646)], startPoint: .topLeading, endPoint: .bottomTrailing))
                BarShape(lime: true, angle: angle, grip: grip).fill(LinearGradient(colors: [Color(hex: 0xD3EF96), Color(hex: 0x9CCB44)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            GloveShape(side: side, angle: angle).fill(.white)
            GloveShape(side: side, angle: angle).stroke(Ink.irisDeep, lineWidth: 2.5)
            if side == .right && pose == .permission {
                MicProp(angle: angle)
            }
        }
        .frame(width: 200, height: 300)
    }
}

private struct MicProp: View {
    var angle: Double
    var body: some View {
        let h = ArmGeometry.joints(side: .right, angle: angle)[3]
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Ink.ink).frame(width: 16, height: 30).offset(x: h.x - 8, y: h.y - 44)
            Path { p in p.addArc(center: CGPoint(x: h.x, y: h.y - 22), radius: 14, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false) }
                .stroke(Ink.ink, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        .transition(.scale.combined(with: .opacity))
    }
}
