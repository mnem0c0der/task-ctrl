import AppKit
import SwiftUI

// Small animated pieces of the dashboard, built on Core Animation.
//
// A SwiftUI animation re-evaluates and lays out the window's view tree on
// every frame; with meters and rows changing each second that alone kept the
// app near 20 % of a core. These layers are animated by the window server
// instead and cost nothing while they move.

// MARK: - Segment meter

/// Bar made of discrete lit segments, like a level meter. A new reading
/// runs up or down segment by segment instead of snapping.
struct SegmentMeter: View {
    let fraction: Double
    let tint: Color
    var segments = 28
    var axis: Axis = .vertical

    var body: some View {
        SegmentMeterLayer(fraction: fraction, tint: tint, segments: segments, axis: axis)
            .accessibilityElement()
            .accessibilityValue(Text(fraction.formatted(.percent.precision(.fractionLength(0)))))
    }
}

private struct SegmentMeterLayer: NSViewRepresentable {
    let fraction: Double
    let tint: Color
    let segments: Int
    let axis: Axis

    func makeNSView(context: Context) -> SegmentMeterView {
        SegmentMeterView()
    }

    func updateNSView(_ view: SegmentMeterView, context: Context) {
        view.tint = NSColor(tint)
        view.segments = segments
        view.isVertical = axis == .vertical
        view.setFraction(fraction)
    }
}

final class SegmentMeterView: NSView {
    var tint = NSColor.systemGreen { didSet { if tint != oldValue { needsLayout = true } } }
    var segments = 28 { didSet { if segments != oldValue { needsLayout = true } } }
    var isVertical = true { didSet { if isVertical != oldValue { needsLayout = true } } }

    private static let gap = 2.0
    /// Time for the reading to move by one segment.
    private static let stepDuration = 0.022

    private let dimLayer = CAShapeLayer()
    private let litLayer = CAShapeLayer()
    /// Uncovers the lit segments; its length is what animates.
    private let cover = CALayer()
    private var lit = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        cover.backgroundColor = NSColor.black.cgColor
        litLayer.mask = cover
        layer?.addSublayer(dimLayer)
        layer?.addSublayer(litLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setFraction(_ fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        // Any non-zero reading lights at least one segment.
        let target = clamped > 0 ? min(max(1, Int((clamped * Double(segments)).rounded())), segments) : 0
        guard target != lit else { return }
        let previous = lit
        lit = target
        guard bounds.width > 0, bounds.height > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyCover()
        let range = previous < target ? Array(previous + 1...target) : Array((target..<previous).reversed())
        let run = CAKeyframeAnimation(keyPath: isVertical ? "bounds.size.height" : "bounds.size.width")
        run.values = range.map { coverLength(for: $0) }
        run.calculationMode = .discrete
        run.duration = min(Self.stepDuration * Double(range.count), 0.45)
        cover.add(run, forKey: "run")
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let count = Double(segments)
        let length = isVertical ? bounds.height : bounds.width
        let step = (length - Self.gap * (count - 1)) / count
        let path = CGMutablePath()
        if step > 0 {
            for index in 0..<segments {
                let offset = Double(index) * (step + Self.gap)
                let bar = isVertical
                    ? CGRect(x: 0, y: bounds.height - offset - step, width: bounds.width, height: step)
                    : CGRect(x: offset, y: 0, width: step, height: bounds.height)
                path.addRoundedRect(in: bar, cornerWidth: min(1.5, bar.width / 2), cornerHeight: min(1.5, bar.height / 2))
            }
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dimLayer.fillColor = tint.withAlphaComponent(0.16).cgColor
            litLayer.fillColor = tint.cgColor
        }
        for shape in [dimLayer, litLayer] {
            shape.frame = bounds
            shape.path = path
            shape.contentsScale = window?.backingScaleFactor ?? 2
        }
        // Grows from the bottom of a vertical meter, from the left of a horizontal one.
        cover.anchorPoint = isVertical ? CGPoint(x: 0, y: 1) : .zero
        cover.position = isVertical ? CGPoint(x: 0, y: bounds.height) : .zero
        cover.removeAnimation(forKey: "run")
        applyCover()
    }

    private func applyCover() {
        let length = coverLength(for: lit)
        cover.bounds = isVertical
            ? CGRect(x: 0, y: 0, width: bounds.width, height: length)
            : CGRect(x: 0, y: 0, width: length, height: bounds.height)
    }

    /// Length that uncovers exactly `count` segments, ending inside the gap after the last.
    private func coverLength(for count: Int) -> Double {
        guard count > 0 else { return 0 }
        let total = Double(segments)
        let length = isVertical ? bounds.height : bounds.width
        let step = (length - Self.gap * (total - 1)) / total
        return Double(count) * (step + Self.gap) - Self.gap / 2
    }
}

// MARK: - Row flash

/// Row background that lights up when `trigger` changes and fades back to
/// its resting `base` opacity.
struct FlashBackground: NSViewRepresentable {
    let tint: Color
    /// Resting opacity, for zebra striping.
    let base: Double
    let trigger: Int

    final class Coordinator {
        var trigger: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 3
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let layer = view.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor(tint).cgColor
        }
        layer.opacity = Float(base)
        if let seen = context.coordinator.trigger, seen != trigger {
            let peak = base + 0.38
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [peak, peak, base]
            fade.keyTimes = [0, 0.15, 1]
            fade.timingFunctions = [
                CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeOut),
            ]
            fade.duration = 2.8
            layer.add(fade, forKey: "flash")
        }
        context.coordinator.trigger = trigger
        CATransaction.commit()
    }
}
