import SwiftUI

/// Helix's mark: two mirrored sine strands (left/right) twisted into a
/// helix under a swelling envelope. Depth changes at the crests; at every
/// crossing one strand is clearly in front and the one behind gets a small
/// gap. Front parts are wider and opaque, back parts narrower and translucent.
/// Used for the app icon, the Lossless badges and the playing title. The same
/// geometry is in `Remote/src/helix.js`, which `tools/make-icon.mjs` renders
/// into the app icon.
enum MarkGeometry {
    /// Design box; the mark is drawn into it with 2 units of margin on every side.
    static let width: CGFloat = 100, height: CGFloat = 60, margin: CGFloat = 2
    static let backOpacity = 0.34, thinness = 0.62

    struct Strand {
        /// Filled outline; width follows depth, ends taper to a point.
        var outline: Path
        /// Opacity by depth along x (depth depends on x only).
        var stops: [Gradient.Stop]
        /// Where the other strand passes in front; cut out of this one.
        var gaps: Path
        /// The x range the opacity stops span.
        var start: CGFloat, end: CGFloat
    }

    /// Both strands in design units. `phase` (radians) turns the helix; small
    /// marks (badges) get fewer, bolder turns.
    static func strands(phase: Double, small: Bool) -> [Strand] {
        let cycles = small ? 1.5 : 2.5, stroke: CGFloat = small ? 8 : 5.2, gap: CGFloat = small ? 2.2 : 1.7, samples = small ? 120 : 360
        let amplitude = height / 2 - stroke / 2, x0 = stroke / 2, span = width - stroke
        func angle(_ t: Double) -> Double { 2 * .pi * cycles * (t - 0.5) + phase }
        func position(_ s: Double, _ t: Double) -> CGPoint {
            let envelope = pow(max(0, sin(.pi * t)), 1.6)
            return CGPoint(x: x0 + t * span, y: height / 2 - s * amplitude * envelope * cos(angle(t)))
        }
        func depth(_ s: Double, _ t: Double) -> Double { s * sin(angle(t)) }   // −1 back … +1 front

        return [1.0, -1.0].map { s in
            var upper: [CGPoint] = [], lower: [CGPoint] = []
            for step in 0...samples {
                let t = Double(step) / Double(samples), point = position(s, t)
                let a = position(s, max(0, t - 1e-3)), b = position(s, min(1, t + 1e-3))
                let length = hypot(b.x - a.x, b.y - a.y), normal = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
                let d = (depth(s, t) + 1) / 2, taper = pow(sin(.pi * t), 0.45)
                let half = stroke * (thinness + (1 - thinness) * d) * taper / 2
                upper.append(CGPoint(x: point.x + normal.x * half, y: point.y + normal.y * half))
                lower.append(CGPoint(x: point.x - normal.x * half, y: point.y - normal.y * half))
            }
            var outline = Path(); outline.addLines(upper + lower.reversed()); outline.closeSubpath()

            let stops = (0...64).map { i -> Gradient.Stop in
                let t = Double(i) / 64, d = (depth(s, t) + 1) / 2
                return .init(color: .black.opacity(backOpacity + (1 - backOpacity) * pow(d, 1.3)), location: t)
            }

            var gaps = Path()
            let window = 0.16 / cycles
            for k in -20...20 {
                let crossing = 0.5 + ((Double(k) + 0.5) * .pi - phase) / (2 * .pi * cycles)   // cos(angle) = 0
                guard crossing >= 0.06, crossing <= 0.94, depth(-s, crossing) >= 0 else { continue }
                var line = Path()
                line.addLines((0...24).map { position(-s, min(1, max(0, crossing - window + 2 * window * Double($0) / 24))) })
                gaps.addPath(line.strokedPath(StrokeStyle(lineWidth: stroke + 2 * gap, lineCap: .round)))
            }
            return Strand(outline: outline, stops: stops, gaps: gaps, start: x0, end: x0 + span)
        }
    }

    /// Draws the mark into `size` with the context's foreground style.
    static func draw(in context: GraphicsContext, size: CGSize, phase: Double) {
        let box = CGSize(width: width + 2 * margin, height: height + 2 * margin)
        let scale = min(size.width / box.width, size.height / box.height)
        var context = context
        context.translateBy(x: (size.width - box.width * scale) / 2 + margin * scale, y: (size.height - box.height * scale) / 2 + margin * scale)
        context.scaleBy(x: scale, y: scale)
        let bounds = CGRect(x: -10, y: -10, width: width + 20, height: height + 20)
        for strand in strands(phase: phase, small: box.width * scale < 26) {
            var layer = context
            if !strand.gaps.isEmpty { layer.clip(to: strand.gaps, options: .inverse) }
            layer.clipToLayer { mask in
                mask.fill(Path(bounds), with: .linearGradient(Gradient(stops: strand.stops),
                                                             startPoint: CGPoint(x: strand.start, y: 0), endPoint: CGPoint(x: strand.end, y: 0)))
            }
            layer.fill(strand.outline, with: .foreground)
        }
    }
}

/// The mark in the current foreground style. While `animating`, the helix
/// slowly turns.
struct LosslessMark: View {
    var animating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if animating && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                mark(phase: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000) * 2.4)
            }
        } else {
            mark(phase: 0)
        }
    }

    private func mark(phase: Double) -> some View {
        Canvas { context, size in MarkGeometry.draw(in: context, size: size, phase: phase) }
            .accessibilityHidden(true)
    }
}

/// The mark for the title that is playing now; it moves only while music plays.
struct PlayingMark: View {
    @ObservedObject private var player = AppModel.shared.player
    var body: some View { LosslessMark(animating: player.playing).accessibilityLabel("Now Playing") }
}
