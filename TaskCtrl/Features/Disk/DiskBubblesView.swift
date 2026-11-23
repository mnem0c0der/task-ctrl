import SwiftUI

/// The contents of a folder as packed circles: area shows size, colour shows
/// what kind of files fill it. Clicking a folder goes into it.
struct DiskBubblesView: View {
    let folder: DiskNode
    let onOpen: (DiskNode) -> Void

    /// A circle in layout space, where the largest has radius 1.
    private struct Bubble: Identifiable, Sendable {
        let id: ObjectIdentifier
        let name: String
        let size: UInt64
        let category: FileCategory
        let isDirectory: Bool
        var center: CGPoint
        let radius: Double
    }

    private struct Item: Sendable {
        let id: ObjectIdentifier
        let name: String
        let size: UInt64
        let category: FileCategory
        let isDirectory: Bool
    }

    /// Past this many the circles are too small to tell apart.
    private static let limit = 180

    @State private var bubbles: [Bubble] = []
    @State private var hovered: ObjectIdentifier?
    /// False until the first layout is ready, so the empty notice doesn't flash.
    @State private var isPacked = false
    /// When the current set of circles started growing in; nil once settled.
    @State private var appearStart: Date?

    private static let growDuration = 0.55
    private static let staggerStep = 0.006
    private static let staggerCap = 50

    var body: some View {
        GeometryReader { proxy in
            let transform = fit(in: proxy.size)

            TimelineView(.animation(paused: appearStart == nil)) { timeline in
            let elapsed = appearStart.map { timeline.date.timeIntervalSince($0) }
            Canvas { context, _ in
                for (index, bubble) in bubbles.enumerated() {
                    // Circles swell out of the middle of the cluster, biggest first.
                    let growth = elapsed.map { Self.growth(at: $0, index: index) } ?? 1
                    guard growth > 0 else { continue }
                    let settled = transform.point(bubble.center)
                    let origin = transform.point(.zero)
                    let center = CGPoint(
                        x: origin.x + (settled.x - origin.x) * growth,
                        y: origin.y + (settled.y - origin.y) * growth
                    )
                    let radius = bubble.radius * transform.scale * growth
                    let rect = CGRect(
                        x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
                    )
                    let color = bubble.category.color
                    // Lit from the upper left, like a ball.
                    context.fill(Path(ellipseIn: rect), with: .radialGradient(
                        Gradient(colors: [color.mix(with: .white, by: 0.35), color, color.mix(with: .black, by: 0.35)]),
                        center: CGPoint(x: center.x - radius * 0.35, y: center.y - radius * 0.35),
                        startRadius: 0,
                        endRadius: radius * 1.5
                    ))
                    context.stroke(
                        Path(ellipseIn: rect.insetBy(dx: 0.5, dy: 0.5)),
                        with: .color(bubble.id == hovered ? .white : color.mix(with: .black, by: 0.45)),
                        lineWidth: bubble.id == hovered ? 2 : 1
                    )

                    if radius > 36 {
                        context.opacity = min(max(growth * 2 - 1, 0), 1)
                        defer { context.opacity = 1 }
                        let label = Text(bubble.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                        context.draw(
                            context.resolve(label),
                            in: CGRect(x: center.x - radius * 0.8, y: center.y - 16, width: radius * 1.6, height: 16)
                        )
                        context.draw(
                            context.resolve(
                                Text(bubble.size.storageFormatted).font(.caption2).foregroundStyle(.white.opacity(0.85))
                            ),
                            at: CGPoint(x: center.x, y: center.y + 8)
                        )
                    }
                }
            }
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hovered = bubble(at: location, transform)?.id
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { tap in
                guard let hit = bubble(at: tap.location, transform), hit.isDirectory,
                      let node = folder.children.first(where: { ObjectIdentifier($0) == hit.id })
                else { return }
                onOpen(node)
            })
            .overlay(alignment: .bottomLeading) {
                if let bubble = bubbles.first(where: { $0.id == hovered }) {
                    HStack(spacing: 8) {
                        Circle().fill(bubble.category.color).frame(width: 10, height: 10)
                        Text(bubble.name).lineLimit(1).truncationMode(.middle)
                        Text(bubble.size.storageFormatted).foregroundStyle(.secondary)
                        if bubble.isDirectory { Text("click to open").foregroundStyle(.tertiary) }
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 6))
                    .padding(10)
                }
            }
            .overlay {
                if bubbles.isEmpty, isPacked {
                    Text("This folder has nothing large enough to draw.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(Color(red: 0.03, green: 0.05, blue: 0.11))
        .task(id: ObjectIdentifier(folder)) {
            // Snapshot on the main actor, pack off it: placing a couple of
            // hundred circles takes a noticeable moment.
            let items = folder.children.prefix(Self.limit).map {
                Item(id: ObjectIdentifier($0), name: $0.name, size: $0.size, category: $0.category, isDirectory: $0.isDirectory)
            }
            // The previous folder stays on screen until the new layout is ready.
            let packed = await Task.detached(priority: .userInitiated) { Self.pack(items) }.value
            guard !Task.isCancelled else { return }
            hovered = nil
            bubbles = packed
            isPacked = true
            let start = Date()
            appearStart = start
            let total = Self.growDuration + Self.staggerStep * Double(Self.staggerCap) + 0.05
            try? await Task.sleep(for: .seconds(total))
            // Stop the timeline once everything has settled, so an idle map costs nothing.
            if appearStart == start { appearStart = nil }
        }
        .accessibilityLabel("Disk map of \(folder.name)")
    }

    // MARK: - Animation

    /// How far circle `index` has grown `elapsed` seconds in: 0 hidden, 1 at
    /// rest, slightly above 1 while it overshoots and springs back.
    private static func growth(at elapsed: TimeInterval, index: Int) -> Double {
        let delay = Double(min(index, staggerCap)) * staggerStep
        let t = min(max((elapsed - delay) / growDuration, 0), 1)
        let overshoot = 1.1
        let u = t - 1
        return 1 + (overshoot + 1) * u * u * u + overshoot * u * u
    }

    // MARK: - Geometry

    private struct Transform {
        var scale: Double = 1
        var offset: CGPoint = .zero

        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
        }
    }

    /// Scales and centres the layout so every circle is inside the view.
    private func fit(in size: CGSize) -> Transform {
        guard !bubbles.isEmpty else { return Transform() }
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for bubble in bubbles {
            minX = min(minX, bubble.center.x - bubble.radius)
            maxX = max(maxX, bubble.center.x + bubble.radius)
            minY = min(minY, bubble.center.y - bubble.radius)
            maxY = max(maxY, bubble.center.y + bubble.radius)
        }
        let padding = 16.0
        let scale = min(
            (size.width - padding * 2) / max(maxX - minX, 0.001),
            (size.height - padding * 2) / max(maxY - minY, 0.001)
        )
        return Transform(
            scale: scale,
            offset: CGPoint(
                x: size.width / 2 - (minX + maxX) / 2 * scale,
                y: size.height / 2 - (minY + maxY) / 2 * scale
            )
        )
    }

    private func bubble(at location: CGPoint, _ transform: Transform) -> Bubble? {
        // Smallest first, so a small circle resting on a big one wins.
        bubbles.reversed().first { bubble in
            let center = transform.point(bubble.center)
            return hypot(location.x - center.x, location.y - center.y) <= bubble.radius * transform.scale
        }
    }

    // MARK: - Packing

    /// Places circles largest first. Each new one is tried touching every
    /// circle already placed, at a ring of angles around it, and takes the
    /// free spot closest to the middle. That keeps the cluster tight.
    private nonisolated static func pack(_ items: [Item]) -> [Bubble] {
        guard let largest = items.map(\.size).max(), largest > 0 else { return [] }
        var placed: [Bubble] = []
        let gap = 0.01
        let directions = (0..<28).map { Double($0) / 28 * 2 * .pi }.map { (cos($0), sin($0)) }

        for item in items.sorted(by: { $0.size > $1.size }) where item.size > 0 {
            // Area, not radius, is proportional to size. Very small items get
            // a minimum radius so they stay visible.
            let radius = max(sqrt(Double(item.size) / Double(largest)), 0.035)
            var center = CGPoint.zero
            var bestDistance = Double.infinity

            for anchor in placed {
                let reach = anchor.radius + radius + gap
                for direction in directions {
                    let candidate = CGPoint(
                        x: anchor.center.x + direction.0 * reach,
                        y: anchor.center.y + direction.1 * reach
                    )
                    let distance = hypot(candidate.x, candidate.y)
                    // Cheap test first: most candidates lose on distance alone.
                    guard distance < bestDistance else { continue }
                    let overlaps = placed.contains {
                        hypot($0.center.x - candidate.x, $0.center.y - candidate.y) < $0.radius + radius + gap * 0.99
                    }
                    if !overlaps {
                        bestDistance = distance
                        center = candidate
                    }
                }
            }
            placed.append(Bubble(
                id: item.id, name: item.name, size: item.size, category: item.category,
                isDirectory: item.isDirectory, center: center, radius: radius
            ))
        }
        return placed
    }
}
