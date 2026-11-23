import SwiftUI

/// Every reading the app has, as a collapsible tree with the lowest and
/// highest value seen since launch (or since the last reset).
struct SensorsView: View {
    /// A tree node together with how deep it sits, ready to draw as a row.
    private struct Row: Identifiable {
        let node: SensorNode
        let depth: Int

        var id: String { node.id }
    }

    @Environment(SystemMonitor.self) private var monitor
    @State private var collapsed: Set<String> = []
    @State private var searchText = ""

    private static let valueWidth: CGFloat = 130

    var body: some View {
        let rows = visibleRows(SensorTree.build(from: monitor.snapshot))

        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                        Divider()
                            .padding(.leading, CGFloat(row.depth) * 18 + 12)
                    }
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .background(Color.black)
        .searchable(text: $searchText, prompt: "Filter sensors")
        .navigationTitle("Sensors")
        .toolbar {
            ToolbarItem {
                Button("Reset Min/Max", systemImage: "arrow.counterclockwise") {
                    monitor.resetSensorRanges()
                }
                .help("Start tracking the lowest and highest values afresh")
            }
        }
    }

    // MARK: - Rows

    /// Flattens the tree, skipping what sits under a collapsed row. While
    /// searching, only matching readings and the rows above them remain.
    private func visibleRows(_ nodes: [SensorNode], depth: Int = 0) -> [Row] {
        var rows: [Row] = []
        for node in nodes {
            if !searchText.isEmpty {
                guard node.readings.contains(where: { matches($0) }) || matches(node) else { continue }
                if node.isReading, !matches(node) { continue }
            }
            rows.append(Row(node: node, depth: depth))
            if !node.isReading, searchText.isEmpty ? !collapsed.contains(node.id) : true {
                rows += visibleRows(node.children, depth: depth + 1)
            }
        }
        return rows
    }

    private func matches(_ node: SensorNode) -> Bool {
        node.name.localizedCaseInsensitiveContains(searchText)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Sensor")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Value").frame(width: Self.valueWidth, alignment: .trailing)
            Text("Min").frame(width: Self.valueWidth, alignment: .trailing)
            Text("Max").frame(width: Self.valueWidth, alignment: .trailing)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let node = row.node
        // Devices and groups show their first reading, like a summary.
        let shown = node.headline
        let range = shown.flatMap { monitor.sensorRanges[$0.id] }

        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if node.isReading {
                    Color.clear.frame(width: 14)
                } else {
                    Button {
                        if collapsed.contains(node.id) {
                            collapsed.remove(node.id)
                        } else {
                            collapsed.insert(node.id)
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(collapsed.contains(node.id) ? -90 : 0))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 20)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(collapsed.contains(node.id) ? "Expand \(node.name)" : "Collapse \(node.name)")
                }
                Image(systemName: node.symbol)
                    .foregroundStyle(tint(for: node))
                    .frame(width: 20)
                Text(node.name)
                    .fontWeight(row.depth == 0 ? .semibold : (node.isReading ? .regular : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, CGFloat(row.depth) * 18)
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                Text(format(shown?.value, shown))
                Text(format(range?.min, shown))
                Text(format(range?.max, shown))
            }
            .monospacedDigit()
            .foregroundStyle(node.isReading ? .primary : .secondary)
            .frame(width: Self.valueWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func format(_ value: Double?, _ node: SensorNode?) -> String {
        guard let value, let unit = node?.unit else { return "—" }
        return unit.format(value)
    }

    private func tint(for node: SensorNode) -> Color {
        switch node.symbol {
        case "thermometer.medium": .orange
        case "bolt.fill": .yellow
        case "gauge.with.dots.needle.33percent": .green
        case "fan": .cyan
        case "memorychip": .purple
        case "cpu": .green
        case "display": .blue
        case "internaldrive": .mint
        default: .blue
        }
    }
}
