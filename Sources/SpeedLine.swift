import CoreGraphics
import Foundation

/// The geometry of the speed chart on Home (#349): the samples as points, the smooth curve through
/// them, and the one move the chart makes when a sample comes in. No SwiftUI here, so `swift test`
/// checks it on the Mac. `SpeedHistoryGraph` draws it.
enum SpeedLine {
    /// The fastest second in either direction, so both lines share one scale.
    static func peak(_ samples: [SpeedSample]) -> Double {
        samples.map { max($0.up, $0.down) }.max() ?? 0
    }

    /// The speed at the top of the chart: the peak with room above it, and at least 1 kbit/s, so an
    /// idle line lies on the bottom.
    static func top(_ samples: [SpeedSample]) -> Double {
        max(1_000, peak(samples)) * 1.15
    }

    /// Each sample in `size`, y down: the newest at the right edge, `SpeedSample.historyDuration`
    /// across, 0 at the bottom and `top` at the top. A sample older than the window lands left of 0.
    static func points(_ samples: [SpeedSample], _ value: KeyPath<SpeedSample, Double>, top: Double, size: CGSize) -> [CGPoint] {
        guard let end = samples.last?.at else { return [] }
        return samples.map { sample in
            let age = end.timeIntervalSince(sample.at) / SpeedSample.historyDuration
            return CGPoint(x: size.width * (1 - age), y: size.height * (1 - sample[keyPath: value] / top))
        }
    }

    struct Segment: Equatable {
        let control1: CGPoint
        let control2: CGPoint
        let to: CGPoint
    }

    /// A monotone cubic through the points (Fritsch and Carlson): smooth, but it never swings past
    /// the samples on either side, so it can't dip below zero next to a spike. Starts at the first
    /// point, one segment to each next one.
    static func curve(through points: [CGPoint]) -> [Segment] {
        guard points.count > 1 else { return [] }
        let n = points.count
        let slopes = (0..<n - 1).map { i in
            let dx = points[i + 1].x - points[i].x
            return dx == 0 ? 0 : (points[i + 1].y - points[i].y) / dx
        }
        var tangents = [CGFloat](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1..<n - 1 {
            tangents[i] = slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2
        }
        for i in 0..<n - 1 {
            if slopes[i] == 0 {
                tangents[i] = 0
                tangents[i + 1] = 0
                continue
            }
            let a = tangents[i] / slopes[i], b = tangents[i + 1] / slopes[i]
            let length = a * a + b * b
            if length > 9 {
                let scale = 3 / length.squareRoot()
                tangents[i] = scale * a * slopes[i]
                tangents[i + 1] = scale * b * slopes[i]
            }
        }
        return (0..<n - 1).map { i in
            let from = points[i], to = points[i + 1]
            let third = (to.x - from.x) / 3
            return Segment(control1: CGPoint(x: from.x + third, y: from.y + tangents[i] * third),
                           control2: CGPoint(x: to.x - third, y: to.y - tangents[i + 1] * third),
                           to: to)
        }
    }

    /// The curve as a path.
    static func path(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for segment in curve(through: points) {
            path.addCurve(to: segment.to, control1: segment.control1, control2: segment.control2)
        }
        return path
    }

    /// Points on the curve at fixed times, every `spacing` seconds of the clock, for a dotted line.
    /// A dash pattern would count from the path's first point, which changes with each sample, so
    /// its dots would crawl along the line. These move with it.
    static func dots(_ samples: [SpeedSample], _ value: KeyPath<SpeedSample, Double>, top: Double, size: CGSize,
                     spacing: TimeInterval = 0.5) -> [CGPoint] {
        let points = SpeedLine.points(samples, value, top: top, size: size)
        let segments = curve(through: points)
        var dots: [CGPoint] = []
        for (i, segment) in segments.enumerated() {
            let from = samples[i].at.timeIntervalSinceReferenceDate, to = samples[i + 1].at.timeIntervalSinceReferenceDate
            guard to > from else { continue }
            var time = (from / spacing).rounded(.up) * spacing
            if time == from, i > 0 { time += spacing } // drawn as the end of the segment before
            while time <= to {
                // The control points sit at thirds of the segment's width, so x is linear in u.
                let u = CGFloat((time - from) / (to - from)), v = 1 - u
                let p0 = points[i]
                let y = v * v * v * p0.y + 3 * v * v * u * segment.control1.y + 3 * v * u * u * segment.control2.y + u * u * u * segment.to.y
                dots.append(CGPoint(x: p0.x + u * (segment.to.x - p0.x), y: y))
                time += spacing
            }
        }
        return dots
    }

    /// What the chart draws: the samples and the scale they're drawn at.
    struct Frame: Equatable {
        var shown: [SpeedSample] = []
        var top: Double = SpeedLine.top([])
    }

    /// The move from one sample to the next. The new line is drawn once, at its place, and starts
    /// out shifted and scaled so it looks exactly like the old one: `slide` (a fraction of the width)
    /// to the right, and `stretch` times as tall, unless that's past `easedScale`. Both then ease to
    /// 0 and 1. The live dot sits on the newest sample and starts `dotRise` (a fraction of the
    /// height) above it, where the old one was.
    struct Step {
        /// How far the scale may change and still ease, as new top over old.
        static let easedScale = 0.5 - 1e-9...2 + 1e-9

        let frame: Frame
        var slide: CGFloat = 0
        var stretch: CGFloat = 1
        var dotRise: CGFloat = 0

        init(from old: Frame?, to samples: [SpeedSample]) {
            let top = SpeedLine.top(samples)
            guard let old, let oldEnd = old.shown.last, let end = samples.last, let first = samples.first else {
                frame = Frame(shown: samples, top: top)
                return
            }
            let gap = max(end.at.timeIntervalSince(oldEnd.at), 0)
            // The samples that just left the window stay while the slide still shows them, plus about
            // one more second, so the line runs to the left edge.
            let leftEdge = SpeedSample.historyDuration + min(gap, SpeedSample.historyDuration)
            let kept = old.shown.filter { $0.at < first.at && end.at.timeIntervalSince($0.at) <= leftEdge + 1.5 }
            frame = Frame(shown: kept + samples, top: top)
            slide = CGFloat(min(gap / SpeedSample.historyDuration, 1))
            // Scaling the drawn line also scales its stroke and dots, which is fine from half to
            // double. A bigger change, like idle to a download, steps the scale with the dot instead.
            let ratio = top / old.top
            if Self.easedScale.contains(ratio) {
                stretch = CGFloat(ratio)
                dotRise = CGFloat(oldEnd.down / old.top - end.down / top)
            }
        }
    }
}
