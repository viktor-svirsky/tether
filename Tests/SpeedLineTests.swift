import CoreGraphics
import XCTest
@testable import TetherCore

/// The geometry of the speed chart on Home (#349): where the samples sit, the curve through them,
/// and how far the line slides when a new sample comes in.
final class SpeedLineTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func samples(_ downs: [Double], up: Double = 0, from offset: TimeInterval = 0) -> [SpeedSample] {
        downs.enumerated().map { SpeedSample(at: start.addingTimeInterval(offset + Double($0.offset)), up: up, down: $0.element) }
    }

    func testTheNewestSampleSitsAtTheRightEdgeAndThirtySecondsBackAtTheLeft() {
        let line = samples(Array(repeating: 0, count: 31))
        let size = CGSize(width: 300, height: 100)
        let points = SpeedLine.points(line, \.down, top: 1_000, size: size)
        XCTAssertEqual(points.last?.x ?? 0, 300, accuracy: 0.001)
        XCTAssertEqual(points.first?.x ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(points[30].x - points[29].x, 10, accuracy: 0.001, "one second is a thirtieth of the width")
    }

    func testZeroIsTheBottomAndTheTopIsTheTop() {
        let line = samples([0, 500, 1_000])
        let points = SpeedLine.points(line, \.down, top: 1_000, size: CGSize(width: 300, height: 100))
        XCTAssertEqual(points.map(\.y), [100, 50, 0])
    }

    /// The scale fits the faster direction, at least 1 kbit/s, with room above the peak for the line.
    func testTheTopLeavesRoomAboveThePeakOfEitherDirection() {
        XCTAssertEqual(SpeedLine.peak(samples([3_000, 4_000], up: 5_000)), 5_000)
        XCTAssertEqual(SpeedLine.top(samples([3_000, 4_000], up: 5_000)), 5_750, accuracy: 0.001)
        XCTAssertEqual(SpeedLine.top(samples([0, 0])), 1_150, accuracy: 0.001, "an idle line lies on the bottom, not in the middle")
        XCTAssertEqual(SpeedLine.top([]), 1_150, accuracy: 0.001)
    }

    /// A spike between quiet seconds: a plain smooth curve would swing below zero next to it, a
    /// speed that can't be. The curve stays between the lowest and the highest sample.
    func testTheCurveNeverSwingsPastTheSamples() {
        let points = SpeedLine.points(samples([0, 0, 4_000, 0, 0, 2_000, 2_000, 0]), \.down, top: 4_000,
                                      size: CGSize(width: 300, height: 100))
        let segments = SpeedLine.curve(through: points)
        XCTAssertEqual(segments.count, points.count - 1)
        for segment in segments {
            for y in [segment.control1.y, segment.control2.y, segment.to.y] {
                XCTAssertTrue((0...100).contains(y), "\(segment)")
            }
        }
        XCTAssertEqual(segments.last?.to, points.last)
    }

    /// The upload dots sit at fixed times, every half second, so they move with the line and don't
    /// crawl along it when a sample comes in or the scale changes. Each lies on the curve.
    func testTheDotsSitAtFixedTimesOnTheCurve() {
        let line = samples([0, 1_000, 1_000], from: 0.25)
        let size = CGSize(width: 300, height: 100)
        let dots = SpeedLine.dots(line, \.down, top: 1_000, size: size)
        // From 0.25 s to 2.25 s: the half seconds 0.5, 1.0, 1.5 and 2.0.
        // The newest sample, at 2.25 s, is the right edge, and 30 s span 300 points.
        XCTAssertEqual(dots.count, 4)
        for (dot, x) in zip(dots, [282.5, 287.5, 292.5, 297.5]) { XCTAssertEqual(dot.x, x, accuracy: 0.001) }
        XCTAssertEqual(dots[2].y, 0, accuracy: 0.001, "flat between two equal samples")
        XCTAssertEqual(dots[3].y, 0, accuracy: 0.001)
        let later = SpeedLine.dots(samples([0, 1_000, 1_000, 1_000], from: 0.25), \.down, top: 1_000, size: size)
        XCTAssertEqual(later.count, 6)
        XCTAssertEqual(later[0].x, dots[0].x - 10, accuracy: 0.001, "a second later the same dot is a second further left")
    }

    /// A sample on a half second gets one dot, not one from each segment it ends and starts.
    func testASampleOnAHalfSecondHasOneDot() {
        let dots = SpeedLine.dots(samples([0, 1_000, 0]), \.down, top: 1_000, size: CGSize(width: 300, height: 100))
        XCTAssertEqual(dots.count, 5)
        XCTAssertEqual(Set(dots.map(\.x)).count, 5)
    }

    func testOneSampleIsNoCurve() {
        XCTAssertTrue(SpeedLine.curve(through: [CGPoint(x: 1, y: 2)]).isEmpty)
        XCTAssertTrue(SpeedLine.curve(through: []).isEmpty)
    }

    func testTheFirstFrameDoesntMove() {
        let step = SpeedLine.Step(from: nil, to: samples([1_000, 2_000]))
        XCTAssertEqual(step.slide, 0)
        XCTAssertEqual(step.stretch, 1)
        XCTAssertEqual(step.dotRise, 0)
        XCTAssertEqual(step.frame.shown, samples([1_000, 2_000]))
    }

    /// A second later the line starts a thirtieth of the width to the right, where it was, and the
    /// sample that just left the window stays drawn, so the left edge doesn't open while it slides.
    func testANewSampleSlidesInFromTheRight() {
        let before = SpeedLine.Step(from: nil, to: samples(Array(repeating: 2_000, count: 31))).frame
        let after = samples(Array(repeating: 2_000, count: 31), from: 1)
        let step = SpeedLine.Step(from: before, to: after)
        XCTAssertEqual(step.slide, 1.0 / 30, accuracy: 0.0001)
        XCTAssertEqual(step.frame.shown.first?.at, start, "the sample that left the window")
        XCTAssertEqual(step.frame.shown.count, 32)
        XCTAssertEqual(step.stretch, 1, "same peak, same scale")
        XCTAssertEqual(step.dotRise, 0)
    }

    /// A new peak doubles the scale: the line starts twice as tall, as it was drawn, and shrinks to
    /// fit, and the dot starts where the last sample was drawn.
    func testANewPeakStartsFromTheOldScale() {
        let before = SpeedLine.Step(from: nil, to: samples([2_000, 1_000])).frame
        let step = SpeedLine.Step(from: before, to: samples([2_000, 1_000, 4_000]))
        XCTAssertEqual(step.frame.top, 4_600, accuracy: 0.001)
        XCTAssertEqual(step.stretch, 2, accuracy: 0.0001)
        // The old dot was drawn 1000 / 2300 up, the new one sits 4000 / 4600 up.
        XCTAssertEqual(step.dotRise, 1_000.0 / 2_300 - 4_000.0 / 4_600, accuracy: 0.0001)
    }

    func testAGapLongerThanTheWindowSlidesOneWidthAtMost() {
        let before = SpeedLine.Step(from: nil, to: samples([1_000])).frame
        let step = SpeedLine.Step(from: before, to: samples([1_000], from: 90))
        XCTAssertEqual(step.slide, 1)
        XCTAssertEqual(step.frame.shown.count, 1, "nothing that old stays")
    }

    func testAnEmptyHistoryEmptiesTheLine() {
        let before = SpeedLine.Step(from: nil, to: samples([1_000, 2_000])).frame
        let step = SpeedLine.Step(from: before, to: [])
        XCTAssertTrue(step.frame.shown.isEmpty)
        XCTAssertEqual(step.slide, 0)
        XCTAssertEqual(step.stretch, 1)
    }
}
