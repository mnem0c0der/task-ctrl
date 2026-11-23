import SwiftUI

enum PerformanceResource: String, CaseIterable, Identifiable {
    case cpu, memory, disk, network, gpu, energy, thermals

    var id: Self { self }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .gpu: "display"
        case .energy: "bolt.circle"
        case .thermals: "thermometer.medium"
        }
    }

    var tint: Color {
        switch self {
        case .cpu: .green
        case .memory: .purple
        case .disk: .mint
        case .network: .blue
        case .gpu: .cyan
        case .energy: .red
        case .thermals: .orange
        }
    }
}

/// Resource list on the left, details of the selected resource on the right.
struct PerformanceView: View {
    @Environment(SystemMonitor.self) private var monitor
    @AppStorage("performanceResource") private var selection: PerformanceResource = .cpu

    var body: some View {
        let snapshot = monitor.snapshot
        let history = monitor.history

        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(PerformanceResource.allCases) { resource in
                        // A real button, so keyboard and VoiceOver can select it too.
                        Button {
                            selection = resource
                        } label: {
                            ResourceRow(
                                resource: resource,
                                summary: ResourceSummary(resource, snapshot: snapshot, history: history),
                                history: history,
                                isSelected: resource == selection
                            )
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(resource == selection ? .isSelected : [])
                    }
                }
                .padding(10)
            }
            .frame(width: 320)

            Divider()

            Group {
                switch selection {
                case .cpu: CPUDetail(snapshot: snapshot, history: history)
                case .memory: MemoryDetail(snapshot: snapshot, history: history)
                case .disk: DiskDetail(snapshot: snapshot, history: history)
                case .network: NetworkDetail(snapshot: snapshot, history: history)
                case .gpu: GPUDetail(snapshot: snapshot, history: history)
                case .energy: EnergyDetail(snapshot: snapshot, history: history)
                case .thermals: ThermalsDetail(snapshot: snapshot, history: history)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.black)
        .navigationTitle("Performance")
    }
}

/// What one row of the resource list says and draws.
struct ResourceSummary {
    let title: String
    let lines: [String]
    let series: [ChartSeries]
    let domain: ClosedRange<Double>

    init(_ resource: PerformanceResource, snapshot: SystemSnapshot, history: [HistoryPoint]) {
        let hardware = HardwareInfo.shared
        let sensors = snapshot.sensors
        let activity = snapshot.activity

        switch resource {
        case .cpu:
            title = "CPU"
            lines = [snapshot.cpu.total.percentFormatted, "\(hardware.logicalCores) logical processors"]
            series = [
                ChartSeries(name: "Utilization", tint: .green) { $0.cpu },
                ChartSeries(name: "Kernel", tint: .red) { $0.kernel },
            ]
            domain = 0...1
        case .memory:
            title = "Memory"
            lines = [
                "\(snapshot.memory.used.memoryFormatted) / \(snapshot.memory.total.memoryFormatted)",
                snapshot.memory.fraction.percentFormatted,
            ]
            series = [ChartSeries(name: "Used", tint: .yellow) { $0.memory }]
            domain = 0...1
        case .disk:
            title = hardware.ssdModel ?? "Disk"
            lines = [
                "R \(activity.diskRead.rateFormatted)",
                "W \(activity.diskWrite.rateFormatted)",
            ]
            series = [
                ChartSeries(name: "Read", tint: .green) { $0.diskRead },
                ChartSeries(name: "Write", tint: .red) { $0.diskWrite },
            ]
            domain = 0...history.ceiling(floor: 1_000_000) { max($0.diskRead, $0.diskWrite) }
        case .network:
            title = "Network"
            lines = [
                "↓ \(activity.networkIn.rateFormatted)",
                "↑ \(activity.networkOut.rateFormatted)",
            ]
            series = [
                ChartSeries(name: "Receive", tint: .green) { $0.networkIn },
                ChartSeries(name: "Send", tint: .red) { $0.networkOut },
            ]
            domain = 0...history.ceiling(floor: 100_000) { max($0.networkIn, $0.networkOut) }
        case .gpu:
            title = "GPU"
            lines = [
                [hardware.gpuName, hardware.gpuCores.map { "\($0) cores" }]
                    .compactMap { $0 }.joined(separator: " · "),
                sensors.gpuUtilization?.percentFormatted ?? "—",
            ]
            series = [ChartSeries(name: "Utilization", tint: .green) { $0.gpu }]
            domain = 0...1
        case .energy:
            title = "Energy"
            lines = [
                sensors.adapterPower == nil ? "On battery" : "AC power",
                sensors.systemPower?.powerFormatted ?? "—",
            ]
            series = [ChartSeries(name: "System", tint: .yellow) { $0.power }]
            domain = 0...history.ceiling(floor: 20) { $0.power }
        case .thermals:
            title = "Thermals"
            lines = [
                ThermalPressure.description,
                sensors.chipTemperature?.temperatureFormatted ?? "—",
            ]
            series = [ChartSeries(name: "Chip", tint: .yellow) { $0.temperature }]
            domain = 20...110
        }
    }
}

private struct ResourceRow: View {
    let resource: PerformanceResource
    let summary: ResourceSummary
    let history: [HistoryPoint]
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: resource.symbol)
                .font(.title3)
                .foregroundStyle(isSelected ? .white : resource.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ForEach(summary.lines, id: \.self) { line in
                    Text(line)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Sparkline(points: history, series: summary.series, domain: summary.domain)
                .frame(width: 78, height: 52)
                .background(resource.tint.opacity(0.12), in: .rect(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(resource.tint.opacity(0.8), lineWidth: 1)
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            isSelected ? Color.accentColor.opacity(0.85) : Color.clear,
            in: .rect(cornerRadius: 8)
        )
    }
}
