import SwiftUI

/// The chip seen the way it is built: performance and efficiency clusters
/// with a chart per core, and the media engine block by block. The GPU has
/// its own page under Performance.
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
                    Text(subtitle(mediaBlocks: snapshot.sensors.mediaEngines.count))
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
                        clusterSize: hardware.performanceClusterSize,
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
                        clusterSize: hardware.efficiencyClusterSize,
                        history: history,
                        clusterLoad: { $0.efficiencyCores }
                    )
                }

                if !snapshot.sensors.mediaEngines.isEmpty {
                    MediaEnginePanel(blocks: snapshot.sensors.mediaEngines, history: history)
                }
            }
            .padding(20)
        }
        .background(Dashboard.pageFill)
        .navigationTitle("Apple Silicon")
    }

    private func subtitle(mediaBlocks: Int) -> String {
        var parts = [
            "\(hardware.performanceCores) performance cores",
            "\(hardware.efficiencyCores) efficiency cores",
        ]
        if let gpu = hardware.gpuCores { parts.append("\(gpu) GPU cores") }
        if mediaBlocks > 0 { parts.append("\(mediaBlocks) media engine blocks") }
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
    let clusterSize: Int?
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
        if let clusterSize { parts.append("\(clusterSize) cores per cluster") }
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

// MARK: - Media engine

/// A chart for each of the chip's video, scaler and codec blocks.
private struct MediaEnginePanel: View {
    let blocks: [MediaEngineReading]
    let history: [HistoryPoint]

    private static let tint = Color.orange

    var body: some View {
        // The busiest block stands for the whole engine.
        let busiest = blocks.map(\.active).max() ?? 0

        Panel(tint: Self.tint) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "film")
                        .font(.title2)
                        .foregroundStyle(Self.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Media Engine")
                            .font(.title3.weight(.semibold))
                        Text("\(blocks.count) blocks")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(busiest.percentFormatted)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Self.tint)
                }

                Text("% Active residency by block")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    ForEach(blocks) { block in
                        MiniChart(
                            title: block.name,
                            value: block.active.percentFormatted,
                            points: history,
                            series: ChartSeries(name: block.name, tint: .green) { $0.mediaEngines[block.name] },
                            tint: Self.tint
                        )
                        .frame(height: 120)
                    }
                }

                Text("Active residency is the share of time a block was kept above its idle voltage: it was in use, not how much of it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
