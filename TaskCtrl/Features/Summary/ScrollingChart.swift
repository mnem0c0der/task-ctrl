import AppKit
import SwiftUI

/// A strip chart that glides to the left continuously instead of jumping
/// once per sample.
///
/// Time is not spread evenly: the chart is cut into equal-width zones, and
/// each zone going left holds twice as much time as the one before. Fresh
/// data sweeps in quickly on the right and slows down as it ages, so the
/// last few seconds are shown in detail and the last half minute still fits.
///
/// Samples arrive about once a second. The chart is drawn slightly in the
/// past, so a new sample is already there by the time the right edge reaches
/// it and the line grows into it smoothly.
///
/// The motion is a Core Animation transform per zone, so it runs in the
/// window server at the display's frame rate and costs the app nothing
/// between samples. (Redrawing a SwiftUI Canvas 30 times a second looked the
/// same and took a quarter of a CPU core.)
struct ScrollingChart: NSViewRepresentable {
    struct Point {
        let date: Date
        /// Position on the vertical axis, 0 at the bottom, 1 at the top.
        let value: Double
    }

    struct Line {
        let tint: Color
        let points: [Point]
    }

    /// Seconds of history in each zone, newest (rightmost) first.
    static let zoneDurations: [TimeInterval] = [2.5, 5, 10, 20]
    /// Seconds of history across the full width.
    static let span = zoneDurations.reduce(0, +)

    enum Style {
        /// Framed, with a grid, a glow under each line and a notch at its current value.
        case full
        /// Bare lines for thumbnails; the surrounding view supplies any frame.
        case spark
    }

    /// Drawn back to front.
    let lines: [Line]
    var tint: Color = .green
    var style = Style.full
    /// How far behind the clock the right edge runs. Has to exceed the gap
    /// between two samples, or the line would stall waiting for the next one.
    var lag: TimeInterval = 1.3
    /// A moment (both bounds equal) or a stretch of time to mark on the chart.
    var selection: ClosedRange<Date>?
    /// Called when the user clicks a moment or drags across a stretch.
    /// Without it the chart ignores the mouse.
    var onSelect: ((ClosedRange<Date>) -> Void)?

    func makeNSView(context: Context) -> ScrollingChartView {
        ScrollingChartView()
    }

    func updateNSView(_ view: ScrollingChartView, context: Context) {
        view.onSelect = onSelect
        view.toolTip = onSelect == nil ? nil : "Click for history. Drag to average a stretch of time."
        view.selection = selection

        // Restart the scroll only when there is something new to draw;
        // a selection change just moves the markers.
        let stamp = lines.map { line in
            let last = line.points.last
            return "\(line.points.count)@\(last?.date.timeIntervalSinceReferenceDate ?? 0)=\(last?.value ?? 0)"
        }
        .joined(separator: ",") + "|\(lag)|\(style)"
        if stamp != view.dataStamp {
            view.dataStamp = stamp
            view.isSpark = style == .spark
            view.lag = lag
            view.tint = NSColor(tint)
            view.lines = lines.map { .init(tint: NSColor($0.tint), points: $0.points) }
            view.rebuild()
        } else {
            view.layoutSelection()
        }
    }
}

final class ScrollingChartView: NSView {
    struct Line {
        let tint: NSColor
        let points: [ScrollingChart.Point]
    }

    var lines: [Line] = []
    var tint = NSColor.systemGreen
    var lag: TimeInterval = 1.3
    /// Thumbnail look: lines only.
    var isSpark = false
    var selection: ClosedRange<Date>?
    var onSelect: ((ClosedRange<Date>) -> Void)?
    /// Identifies the data last drawn, so unchanged data isn't laid out again.
    var dataStamp = ""

    /// One slice of the chart with its own time scale.
    private final class Zone {
        /// Age of the data on the zone's right edge, and how much time it holds.
        let startAge: TimeInterval
        let duration: TimeInterval
        /// Where the zone sits in the chart, and how fast its content moves.
        var frame = CGRect.zero
        var speed = 0.0

        /// Cuts the content off at the zone's edges.
        let clip = CALayer()
        /// Holds the content; this is what slides.
        let scroll = CALayer()
        var strokes: [(glow: CAShapeLayer, stroke: CAShapeLayer)] = []
        /// Vertical grid lines. They mark moments in time, so they travel
        /// with the data and sit wider apart where time is stretched.
        let grid = CAShapeLayer()
        let shade = CALayer()
        let edges = [CAShapeLayer(), CAShapeLayer()]

        init(startAge: TimeInterval, duration: TimeInterval) {
            self.startAge = startAge
            self.duration = duration
            clip.masksToBounds = true
            clip.addSublayer(scroll)
            grid.fillColor = nil
            grid.lineWidth = 1
            grid.zPosition = -1
            scroll.addSublayer(grid)
            shade.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.2).cgColor
            shade.isHidden = true
            scroll.addSublayer(shade)
            for edge in edges {
                edge.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
                edge.lineWidth = 1
                edge.lineDashPattern = [3, 3]
                edge.isHidden = true
                edge.zPosition = 1
                scroll.addSublayer(edge)
            }
        }

        /// Horizontal position inside the zone of data `age` seconds old at layout time.
        func x(age: TimeInterval) -> Double {
            frame.width - (age - startAge) * speed
        }

        /// Takes a path drawn with x in seconds relative to the right edge
        /// (negative is the past) into the zone's own coordinates.
        var fromSeconds: CGAffineTransform {
            CGAffineTransform(a: speed, b: 0, c: 0, d: 1, tx: frame.width + startAge * speed, ty: 0)
        }
    }

    /// How long the scroll keeps going if no new sample turns up.
    private static let horizon: TimeInterval = 5
    private static let inset = 2.0

    private let frameLayer = CAShapeLayer()
    private let gridLayer = CAShapeLayer()
    /// Clips the zones to the chart's rounded frame.
    private let plotLayer = CALayer()
    private let plotMask = CAShapeLayer()
    private let zones: [Zone]
    private var markers: [CAShapeLayer] = []

    /// The moment that sat on the right edge when the lines were last laid
    /// out; everything inside the zones is positioned relative to it.
    private var anchor = Date()
    /// Where the current drag started, in time and in view coordinates.
    private var drag: (date: Date, x: Double)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        var age = 0.0
        zones = ScrollingChart.zoneDurations.map { duration in
            defer { age += duration }
            return Zone(startAge: age, duration: duration)
        }
        super.init(frame: frame)
        wantsLayer = true
        guard let layer else { return }
        frameLayer.lineWidth = 1
        gridLayer.lineWidth = 1
        gridLayer.fillColor = nil
        plotLayer.mask = plotMask
        zones.forEach { plotLayer.addSublayer($0.clip) }
        layer.addSublayer(frameLayer)
        layer.addSublayer(gridLayer)
        layer.addSublayer(plotLayer)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations are dropped while the view is out of a window.
        rebuild()
    }

    /// Lays everything out for this instant and restarts the scroll from it.
    /// Safe to call at any time: the picture before and after is the same.
    func rebuild() {
        let size = bounds.size
        guard size.width > 8, size.height > 4, window != nil else { return }
        let scale = window?.backingScaleFactor ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        effectiveAppearance.performAsCurrentDrawingAppearance {
            layoutFrame(size: size)
            syncLineLayers(scale: scale)

            let end = Date().addingTimeInterval(-lag)
            anchor = end
            layoutSelection()

            let ticks = Self.timeGrid(end: end, height: size.height, slowest: zones.map(\.speed).min() ?? 1)
            for zone in zones {
                var transform = zone.fromSeconds
                zone.grid.path = isSpark ? nil : ticks.copy(using: &transform)
                zone.grid.strokeColor = tint.withAlphaComponent(0.12).cgColor
                zone.grid.contentsScale = scale
            }

            for (index, line) in lines.enumerated() {
                let path = Self.path(for: line.points, height: size.height, end: end)
                for zone in zones {
                    var transform = zone.fromSeconds
                    let placed = path?.copy(using: &transform)
                    let layers = zone.strokes[index]
                    layers.glow.path = isSpark ? nil : placed
                    layers.stroke.path = placed
                    layers.stroke.lineWidth = isSpark ? 1.5 : 1.8
                    layers.glow.strokeColor = line.tint.withAlphaComponent(0.22).cgColor
                    layers.stroke.strokeColor = line.tint.cgColor
                }
                animateMarker(markers[index], along: line.points, from: end, size: size)
            }

            for zone in zones {
                let scroll = CABasicAnimation(keyPath: "transform.translation.x")
                scroll.fromValue = 0
                scroll.toValue = -zone.speed * Self.horizon
                scroll.duration = Self.horizon
                scroll.timingFunction = CAMediaTimingFunction(name: .linear)
                scroll.fillMode = .forwards
                scroll.isRemovedOnCompletion = false
                zone.scroll.add(scroll, forKey: "scroll")
            }
        }
    }

    // MARK: - Selection

    /// Puts the selection markers on the moments they mark.
    func layoutSelection() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let selection, bounds.width > 8 else {
            for zone in zones {
                zone.shade.isHidden = true
                zone.edges.forEach { $0.isHidden = true }
            }
            return
        }
        let isMoment = selection.lowerBound == selection.upperBound
        // Far outside a zone the positions get huge; they are clipped anyway.
        let limit = bounds.width * 4
        for zone in zones {
            let left = min(max(zone.x(age: anchor.timeIntervalSince(selection.lowerBound)), -limit), limit)
            let right = min(max(zone.x(age: anchor.timeIntervalSince(selection.upperBound)), -limit), limit)
            zone.shade.isHidden = isMoment
            zone.shade.frame = CGRect(x: left, y: 0, width: max(right - left, 0), height: bounds.height)
            for (edge, x) in zip(zone.edges, [left, right]) {
                let line = CGMutablePath()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: bounds.height))
                edge.path = line
                edge.isHidden = false
            }
            zone.edges[1].isHidden = isMoment
        }
    }

    /// The moment currently drawn at horizontal position `x`.
    private func moment(at x: Double) -> Date {
        let clamped = min(max(x, 0), bounds.width)
        let zone = zones.first { clamped >= $0.frame.minX } ?? zones[zones.count - 1]
        let age = zone.startAge + (zone.frame.maxX - clamped) / max(zone.speed, 0.001)
        return Date().addingTimeInterval(-lag - age)
    }

    override func mouseDown(with event: NSEvent) {
        guard let onSelect, bounds.width > 8 else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        // Clicks aimed elsewhere can be routed here; only take our own.
        guard bounds.contains(point) else { return }
        let date = moment(at: point.x)
        drag = (date: date, x: Double(point.x))
        onSelect(date...date)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let onSelect, let drag else { return super.mouseDragged(with: event) }
        let x = convert(event.locationInWindow, from: nil).x
        // A click with a slightly unsteady hand still marks a single moment.
        guard abs(x - drag.x) >= 3 else { return onSelect(drag.date...drag.date) }
        let date = moment(at: x)
        onSelect(min(drag.date, date)...max(drag.date, date))
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }

    // MARK: - Static parts

    private func layoutFrame(size: CGSize) {
        let frame = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let outline = CGPath(roundedRect: frame, cornerWidth: 3, cornerHeight: 3, transform: nil)
        frameLayer.isHidden = isSpark
        gridLayer.isHidden = isSpark
        frameLayer.frame = bounds
        frameLayer.path = outline
        frameLayer.fillColor = tint.withAlphaComponent(0.05).cgColor
        frameLayer.strokeColor = tint.withAlphaComponent(0.7).cgColor

        // Only the horizontal lines stand still; the vertical ones belong to
        // the zones. An even number of rows keeps a line on the 50 % mark.
        let grid = CGMutablePath()
        let rows = max(2, 2 * Int((size.height / 36).rounded()))
        for row in 1..<rows {
            let y = (size.height * Double(row) / Double(rows)).rounded() + 0.5
            grid.move(to: CGPoint(x: 1, y: y))
            grid.addLine(to: CGPoint(x: size.width - 1, y: y))
        }
        gridLayer.frame = bounds
        gridLayer.path = grid
        gridLayer.strokeColor = tint.withAlphaComponent(0.12).cgColor

        plotLayer.frame = bounds
        plotMask.frame = bounds
        plotMask.path = outline

        // Equal-width zones from the right edge. Whole-point boundaries, so
        // neighbouring zones meet without a seam.
        let count = Double(zones.count)
        for (index, zone) in zones.enumerated() {
            let right = (size.width * (1 - Double(index) / count)).rounded()
            let left = index == zones.count - 1 ? 0 : (size.width * (1 - Double(index + 1) / count)).rounded()
            zone.frame = CGRect(x: left, y: 0, width: right - left, height: size.height)
            zone.speed = zone.frame.width / zone.duration
            zone.clip.frame = zone.frame
            zone.scroll.frame = zone.clip.bounds
        }
    }

    private func syncLineLayers(scale: CGFloat) {
        for zone in zones {
            while zone.strokes.count > lines.count {
                let last = zone.strokes.removeLast()
                last.glow.removeFromSuperlayer()
                last.stroke.removeFromSuperlayer()
            }
            while zone.strokes.count < lines.count {
                let glow = CAShapeLayer(), stroke = CAShapeLayer()
                for (shape, width) in [(glow, 5.0), (stroke, 1.8)] {
                    shape.fillColor = nil
                    shape.lineWidth = width
                    shape.lineJoin = .round
                    shape.lineCap = .round
                    zone.scroll.addSublayer(shape)
                }
                zone.strokes.append((glow, stroke))
            }
            for layers in zone.strokes {
                layers.glow.contentsScale = scale
                layers.stroke.contentsScale = scale
            }
        }
        while markers.count > lines.count {
            markers.removeLast().removeFromSuperlayer()
        }
        while markers.count < lines.count {
            // A notch on the right edge at the line's current value.
            let marker = CAShapeLayer()
            let notch = CGMutablePath()
            notch.move(to: CGPoint(x: -7, y: 0))
            notch.addLine(to: CGPoint(x: -1, y: -4))
            notch.addLine(to: CGPoint(x: -1, y: 4))
            notch.closeSubpath()
            marker.path = notch
            marker.fillColor = NSColor.white.cgColor
            marker.strokeColor = NSColor.black.withAlphaComponent(0.6).cgColor
            marker.lineWidth = 0.5
            layer?.addSublayer(marker)
            markers.append(marker)
        }
        markers.forEach { $0.contentsScale = scale }
    }

    // MARK: - Lines

    /// Vertical lines at whole multiples of a few seconds of clock time, with
    /// x in seconds relative to `end`. Tied to the clock rather than to
    /// `end`, so they stay put on the data from one layout to the next.
    private static func timeGrid(end: Date, height: Double, slowest: Double) -> CGPath {
        // Keep the lines at least 4 pt apart where time is most compressed.
        let interval = max(1, (4 / max(slowest, 0.01)).rounded(.up))
        let path = CGMutablePath()
        let now = end.timeIntervalSinceReferenceDate
        // From past the left edge to far enough ahead to last until the next layout.
        var tick = ((now - ScrollingChart.span - interval) / interval).rounded(.down) * interval
        while tick < now + horizon + interval {
            path.move(to: CGPoint(x: tick - now, y: 1))
            path.addLine(to: CGPoint(x: tick - now, y: height - 1))
            tick += interval
        }
        return path
    }

    private static func y(_ value: Double, height: Double) -> Double {
        inset + (height - inset * 2) * (1 - min(max(value, 0), 1))
    }

    /// The line with x in seconds relative to `end` (the past is negative)
    /// and y in points. Each zone stretches it to its own time scale.
    private static func path(for points: [ScrollingChart.Point], height: Double, end: Date) -> CGPath? {
        let placed = points.map { point in
            CGPoint(x: point.date.timeIntervalSince(end), y: y(point.value, height: height))
        }
        // Skip what has scrolled off, keeping one point beyond the left edge.
        let firstVisible = placed.firstIndex { $0.x >= -ScrollingChart.span } ?? placed.count
        let visible = placed[max(firstVisible - 1, 0)...]
        guard let first = visible.first, let last = visible.last else { return nil }

        let path = CGMutablePath()
        path.move(to: first)
        var previous = first
        for point in visible.dropFirst() {
            // Control points level with each end: the curve leaves and
            // arrives flat, so it never overshoots a sample.
            let middle = (previous.x + point.x) / 2
            path.addCurve(
                to: point,
                control1: CGPoint(x: middle, y: previous.y),
                control2: CGPoint(x: middle, y: point.y)
            )
            previous = point
        }
        // Hold the last value in case the next sample is late.
        path.addLine(to: CGPoint(x: last.x + horizon + 2, y: last.y))
        return path
    }

    /// Value of the drawn curve at a moment in time, following the same
    /// easing between samples as `path(for:)`.
    private static func value(of points: [ScrollingChart.Point], at date: Date) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if date <= first.date { return first.value }
        if date >= last.date { return last.value }
        // Binary search for the sample just before `date`.
        var low = 0, high = points.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if points[middle].date <= date { low = middle } else { high = middle }
        }
        let from = points[low], to = points[high]
        let span = to.date.timeIntervalSince(from.date)
        guard span > 0 else { return to.value }
        let target = date.timeIntervalSince(from.date) / span
        // With those control points the curve runs along
        // x(s) = 1.5s − 1.5s² + s³, y(s) = 3s² − 2s³; find s by bisection.
        var a = 0.0, b = 1.0
        for _ in 0..<20 {
            let s = (a + b) / 2
            if 1.5 * s - 1.5 * s * s + s * s * s < target { a = s } else { b = s }
        }
        let s = (a + b) / 2
        return from.value + (to.value - from.value) * (3 * s * s - 2 * s * s * s)
    }

    /// Moves the notch along the heights the line will have at the right edge
    /// over the coming seconds.
    private func animateMarker(
        _ marker: CAShapeLayer, along points: [ScrollingChart.Point], from end: Date, size: CGSize
    ) {
        guard !isSpark, let now = Self.value(of: points, at: end) else {
            marker.isHidden = true
            marker.removeAnimation(forKey: "track")
            return
        }
        marker.isHidden = false
        marker.position = CGPoint(x: size.width, y: Self.y(now, height: size.height))

        let steps = Int(Self.horizon * 30)
        let heights = (0...steps).map { step -> Double in
            let date = end.addingTimeInterval(Self.horizon * Double(step) / Double(steps))
            return Self.y(Self.value(of: points, at: date) ?? now, height: size.height)
        }
        let track = CAKeyframeAnimation(keyPath: "position.y")
        track.values = heights
        track.duration = Self.horizon
        track.calculationMode = .linear
        track.fillMode = .forwards
        track.isRemovedOnCompletion = false
        marker.add(track, forKey: "track")
    }
}

/// Scale labels beside a chart, spread evenly from top to bottom.
struct AxisLabels: View {
    let labels: [String]
    let tint: Color
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                if index > 0 { Spacer(minLength: 0) }
                Text(label)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(tint)
    }
}
