import SwiftUI

/// The chip seen the way it is built: performance and efficiency clusters
/// with a chart per core, plus the GPU.
struct AppleSiliconView: View {
    @Environment(SystemMonitor.self) private var monitor

    private let hardware = HardwareInfo.shared

    var body: some View {
        let snapshot = monitor.snapshot
        let history = monitor.history

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(hardware.chipName)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 14) {
                    ClusterPanel(
                        title: "Performance cores",
                        symbol: "hare",
                        tint: .green,
                        kind: .performance,
                        load: snapshot.cpu.performance,
                        cache: hardware.performanceL2Cache,
                        history: history,
                        clusterLoad: { $0.performanceCores }
                    )
                    ClusterPanel(
                        title: "Efficiency cores",
                        symbol: "tortoise",
                        tint: .cyan,
                        kind: .efficiency,
                        load: snapshot.cpu.efficiency,
                        cache: hardware.efficiencyL2Cache,
                        history: history,
                        clusterLoad: { $0.efficiencyCores }
                    )
                }

                GPUPanel(sensors: snapshot.sensors, history: history)
            }
            .padding(20)
        }
        .background(Color.black)
        .navigationTitle("Apple Silicon")
    }

    private var subtitle: String {
        var parts = [
            "\(hardware.performanceCores) performance cores",
            "\(hardware.efficiencyCores) efficiency cores",
        ]
        if let gpu = hardware.gpuCores { parts.append("\(gpu) GPU cores") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Cluster

private struct ClusterPanel: View {
    let title: String
    let symbol: String
    let tint: Color
    let kind: HardwareInfo.CoreKind
    let load: CPUUsage.Load
    let cache: UInt64?
    let history: [HistoryPoint]
    let clusterLoad: (HistoryPoint) -> CPUUsage.Load

    /// Logical CPU numbers that belong to this cluster.
    private var coreIndices: [Int] {
        HardwareInfo.shared.coreKinds.enumerated().filter { $0.element == kind }.map(\.offset)
    }

    var body: some View {
        Panel(tint: tint) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                        Text(details)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(load.total.percentFormatted)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                }

                SeriesChart(
                    title: "% Utilization",
                    points: history,
                    series: [
                        ChartSeries(name: "Utilization", tint: .green) { clusterLoad($0).total },
                        ChartSeries(name: "Kernel", tint: .red) { clusterLoad($0).system },
                    ],
                    tint: tint
                )
                .frame(height: 190)

                Text("% Utilization by core")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                    ForEach(coreIndices, id: \.self) { index in
                        CoreTile(index: index, tint: tint, history: history)
                    }
                }
            }
        }
    }

    private var details: String {
        var parts = ["\(coreIndices.count) cores"]
        if let cache { parts.append("\(cache.memoryFormatted) L2 cache") }
        return parts.joined(separator: " · ")
    }
}

/// Small chart of one core: total load and the kernel's share of it.
private struct CoreTile: View {
    let index: Int
    let tint: Color
    let history: [HistoryPoint]

    var body: some View {
        let current = history.last.flatMap { $0.cores.indices.contains(index) ? $0.cores[index] : nil }

        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("CPU \(index)")
                Spacer(minLength: 2)
                Text(current?.total.formatted(.percent.precision(.fractionLength(0))) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.monospacedDigit())
            Sparkline(
                points: history,
                series: [
                    ChartSeries(name: "Utilization", tint: .green) {
                        $0.cores.indices.contains(index) ? $0.cores[index].total : nil
                    },
                    ChartSeries(name: "Kernel", tint: .red) {
                        $0.cores.indices.contains(index) ? $0.cores[index].system : nil
                    },
                ],
                domain: 0...1
            )
            .frame(height: 40)
        }
        .padding(6)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(tint.opacity(0.7), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU \(index)")
        .accessibilityValue(current?.total.percentFormatted ?? "No reading")
    }
}

// MARK: - GPU

private struct GPUPanel: View {
    let sensors: SensorReadings
    let history: [HistoryPoint]

    var body: some View {
        let hardware = HardwareInfo.shared

        Panel(tint: .orange) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "display")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GPU")
                            .font(.title3.weight(.semibold))
                        Text([
                            hardware.gpuCores.map { "\($0) cores" },
                            sensors.gpuMemory.map { "\($0.memoryFormatted) in use" },
                            sensors.gpuPower.map { $0.powerFormatted },
                        ].compactMap { $0 }.joined(separator: " · "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(sensors.gpuUtilization?.percentFormatted ?? "—")
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.orange)
                        .contentTransition(.numericText())
                }
                SeriesChart(
                    title: "% Utilization",
                    points: history,
                    series: [ChartSeries(name: "Utilization", tint: .green) { $0.gpu }],
                    tint: .orange
                )
                .frame(height: 170)
            }
        }
    }
}
