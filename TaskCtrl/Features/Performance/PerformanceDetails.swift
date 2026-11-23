import SwiftUI

// MARK: - CPU

struct CPUDetail: View {
    let snapshot: SystemSnapshot
    let history: [HistoryPoint]

    private let hardware = HardwareInfo.shared

    var body: some View {
        DetailPage(
            title: "CPU",
            subtitle: "\(hardware.chipName) · \(hardware.logicalCores) logical processors",
            value: snapshot.cpu.total.percentFormatted,
            fraction: snapshot.cpu.total,
            tint: .green
        ) {
            Text("% Utilization by processor class")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                SeriesChart(
                    title: "Performance cores",
                    points: history,
                    series: [
                        ChartSeries(name: "Utilization", tint: .green) { $0.performanceCores.total },
                        ChartSeries(name: "Kernel", tint: .red) { $0.performanceCores.system },
                    ],
                    tint: .green
                )
                SeriesChart(
                    title: "Efficiency cores",
                    points: history,
                    series: [
                        ChartSeries(name: "Utilization", tint: .green) { $0.efficiencyCores.total },
                        ChartSeries(name: "Kernel", tint: .red) { $0.efficiencyCores.system },
                    ],
                    tint: .cyan
                )
            }
            .frame(height: 280)

            if !snapshot.cpu.cores.isEmpty {
                coreMeters
            }

            HStack(alignment: .top) {
                StatValue(title: "Utilization", value: snapshot.cpu.total.percentFormatted)
                StatValue(title: "Processes", value: snapshot.processCount.formatted())
                StatValue(title: "Threads", value: threadCount)
                StatValue(title: "Up time", value: uptime)
            }

            PropertyGrid(properties: properties)
        }
    }

    /// One small level meter per core, grouped by kind.
    private var coreMeters: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(snapshot.cpu.cores.enumerated()), id: \.offset) { index, core in
                let efficient = hardware.coreKinds.indices.contains(index)
                    && hardware.coreKinds[index] == .efficiency
                VStack(spacing: 4) {
                    SegmentMeter(fraction: core.total, tint: efficient ? .cyan : .green, segments: 10)
                        .frame(height: 54)
                    Text(efficient ? "E\(index)" : "P\(index)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 36)
                .help("Core \(index): \(core.total.percentFormatted)")
            }
        }
    }

    /// Thread counts of other users' processes need the helper; without it
    /// the total covers only what could be read.
    private var threadCount: String {
        let total = snapshot.processes.reduce(0) { $0 + $1.threads }
        return total > 0 ? total.formatted() : "—"
    }

    private var uptime: String {
        hardware.bootDate.map { snapshot.date.timeIntervalSince($0).uptimeFormatted } ?? "—"
    }

    private var properties: [(name: String, value: String)] {
        func size(_ bytes: UInt64?) -> String { bytes?.memoryFormatted ?? "Unavailable" }
        return [
            ("Physical cores", String(hardware.physicalCores)),
            ("Logical processors", String(hardware.logicalCores)),
            ("Performance cores", String(hardware.performanceCores)),
            ("Efficiency cores", String(hardware.efficiencyCores)),
            ("L1 cache (P core)", size(hardware.performanceL1Cache)),
            ("L1 cache (E core)", size(hardware.efficiencyL1Cache)),
            ("L2 cache (P cluster)", size(hardware.performanceL2Cache)),
            ("L2 cache (E cluster)", size(hardware.efficiencyL2Cache)),
            ("Load average", snapshot.activity.loadAverage.formatted(.number.precision(.fractionLength(2)))),
            ("Model", hardware.modelIdentifier),
        ]
    }
}

// MARK: - Memory

struct MemoryDetail: View {
    let snapshot: SystemSnapshot
    let history: [HistoryPoint]

    var body: some View {
        let memory = snapshot.memory
        let totalGB = Double(memory.total) / 1_073_741_824

        DetailPage(
            title: "Memory",
            subtitle: "\(memory.used.memoryFormatted) of \(memory.total.memoryFormatted) in use",
            value: memory.fraction.percentFormatted,
            fraction: memory.fraction,
            tint: .purple
        ) {
            SeriesChart(
                title: "Memory in use",
                points: history,
                series: [ChartSeries(name: "Used", tint: .purple) { $0.memory * totalGB }],
                tint: .purple,
                domain: 0...max(totalGB, 1),
                label: { "\(Int($0)) GB" }
            )
            .frame(height: 280)

            HStack(alignment: .top) {
                StatValue(title: "In use", value: memory.used.memoryFormatted)
                StatValue(
                    title: "Available",
                    value: (memory.total > memory.used ? memory.total - memory.used : 0).memoryFormatted
                )
                StatValue(title: "Cached", value: memory.cached.memoryFormatted)
                StatValue(title: "Swap used", value: memory.swapUsed == 0 ? "0" : memory.swapUsed.memoryFormatted)
            }

            PropertyGrid(properties: [
                ("App memory", memory.app.memoryFormatted),
                ("Wired", memory.wired.memoryFormatted),
                ("Compressed", memory.compressed.memoryFormatted),
                ("Installed", memory.total.memoryFormatted),
                ("Pressure", pressure),
            ])
        }
    }

    private var pressure: String {
        switch snapshot.activity.memoryPressure {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

// MARK: - Disk

struct DiskDetail: View {
    let snapshot: SystemSnapshot
    let history: [HistoryPoint]

    @State private var volumes: [Volume] = []

    var body: some View {
        let activity = snapshot.activity
        let ceiling = history.ceiling(floor: 1_000_000) { max($0.diskRead, $0.diskWrite) }

        DetailPage(
            title: HardwareInfo.shared.ssdModel ?? "Disk",
            subtitle: "Reads and writes across all drives",
            value: (activity.diskRead + activity.diskWrite).rateFormatted,
            fraction: nil,
            tint: .mint
        ) {
            SeriesChart(
                title: "Transfer rate",
                points: history,
                series: [
                    ChartSeries(name: "Read", tint: .green) { $0.diskRead },
                    ChartSeries(name: "Write", tint: .red) { $0.diskWrite },
                ],
                tint: .mint,
                domain: 0...ceiling,
                label: { $0.rateFormatted }
            )
            .frame(height: 280)

            HStack(alignment: .top) {
                StatValue(title: "Read", value: activity.diskRead.rateFormatted)
                StatValue(title: "Write", value: activity.diskWrite.rateFormatted)
            }

            PropertyGrid(properties: volumes.flatMap { volume in
                [
                    ("\(volume.name) capacity", volume.total.storageFormatted),
                    ("\(volume.name) free", volume.available.storageFormatted),
                ]
            })
        }
        .task { volumes = Volume.mounted() }
    }
}

// MARK: - Network

struct NetworkDetail: View {
    let snapshot: SystemSnapshot
    let history: [HistoryPoint]

    var body: some View {
        let activity = snapshot.activity
        let ceiling = history.ceiling(floor: 100_000) { max($0.networkIn, $0.networkOut) }

        DetailPage(
            title: "Network",
            subtitle: "Wi-Fi and Ethernet combined",
            value: (activity.networkIn + activity.networkOut).rateFormatted,
            fraction: nil,
            tint: .blue
        ) {
            SeriesChart(
                title: "Throughput",
                points: history,
                series: [
                    ChartSeries(name: "Receive", tint: .green) { $0.networkIn },
                    ChartSeries(name: "Send", tint: .red) { $0.networkOut },
                ],
                tint: .blue,
                domain: 0...ceiling,
                label: { $0.rateFormatted }
            )
            .frame(height: 280)

            HStack(alignment: .top) {
                StatValue(title: "Receiving", value: activity.networkIn.rateFormatted)
                StatValue(title: "Sending", value: activity.networkOut.rateFormatted)
            }

            Text("Top processes by traffic")
                .font(.callout)
                .foregroundStyle(.secondary)
            PropertyGrid(properties: topTalkers)
        }
    }

    private var topTalkers: [(name: String, value: String)] {
        snapshot.processes
            .filter { $0.network >= 1 }
            .sorted { $0.network > $1.network }
            .prefix(8)
            .map { ("\($0.name) (\($0.pid))", $0.network.rateFormatted) }
    }
}

// MARK: - GPU

struct GPUDetail: View {
    let snapshot: SystemSnapshot
    let history: [HistoryPoint]

    var body: some View {
        let sensors = snapshot.sensors
        let hardware = HardwareInfo.shared

        DetailPage(
            title: "GPU",
            subtitle: [hardware.gpuName, hardware.gpuCores.map { "\($0) cores" }]
                .compactMap { $0 }.joined(separator: " · "),
            value: sensors.gpuUtilization?.percentFormatted ?? "—",
            fraction: sensors.gpuUtilization ?? 0,
            tint: .cyan
        ) {
            SeriesChart(
                title: "Utilization",
                points: history,
                series: [ChartSeries(name: "Utilization", tint: .green) { $0.gpu }],
                tint: .cyan
            )
            .frame(height: 280)

            HStack(alignment: .top) {
                StatValue(title: "Utilization", value: sensors.gpuUtilization?.percentFormatted ?? "—")
                StatValue(title: "Memory in use", value: sensors.gpuMemory?.memoryFormatted ?? "—")
                StatValue(title: "Power", value: sensors.gpuPower?.powerFormatted ?? "—")
            }

            PropertyGrid(properties: [
                ("Model", hardware.gpuName ?? "Unavailable"),
                ("Cores", hardware.gpuCores.map(String.init) ?? "Unavailable"),
                ("Memory", "Shared with system"),
            ])
        }
    }
}

// MARK: - Energy

struct EnergyDetail: View {
    let snapshot: SystemSnapshot
    let history: [HistoryPoint]

    var body: some View {
        let sensors = snapshot.sensors
        let ceiling = max(20, (history.ceiling(floor: 0) { $0.power } / 20).rounded(.up) * 20)

        DetailPage(
            title: "Energy",
            subtitle: sensors.adapterPower == nil ? "Running on battery" : "Connected to power",
            value: sensors.systemPower?.powerFormatted ?? "—",
            fraction: nil,
            tint: .red
        ) {
            SeriesChart(
                title: "System power",
                points: history,
                series: [ChartSeries(name: "System", tint: .yellow) { $0.power }],
                tint: .red,
                domain: 0...ceiling,
                label: { "\(Int($0)) W" }
            )
            .frame(height: 280)

            HStack(alignment: .top) {
                StatValue(title: "System", value: sensors.systemPower?.powerFormatted ?? "—")
                StatValue(title: "Charger", value: sensors.adapterPower?.powerFormatted ?? "—")
                StatValue(title: "GPU", value: sensors.gpuPower?.powerFormatted ?? "—")
                StatValue(
                    title: "Processes",
                    value: snapshot.processPower > 0 ? snapshot.processPower.powerFormatted : "—"
                )
            }

            Text("Top processes by power")
                .font(.callout)
                .foregroundStyle(.secondary)
            PropertyGrid(properties: snapshot.processes
                .filter { $0.power >= 0.001 }
                .sorted { $0.power > $1.power }
                .prefix(8)
                .map { ("\($0.name) (\($0.pid))", $0.power.smallPowerFormatted) })
        }
    }
}

// MARK: - Thermals

enum ThermalPressure {
    /// The system's own verdict on how hot it is running.
    static var description: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Nominal thermal pressure"
        case .fair: "Fair thermal pressure"
        case .serious: "Serious thermal pressure"
        case .critical: "Critical thermal pressure"
        @unknown default: "Unknown thermal pressure"
        }
    }
}

struct ThermalsDetail: View {
    let snapshot: SystemSnapshot
    let history: [HistoryPoint]

    var body: some View {
        let sensors = snapshot.sensors

        DetailPage(
            title: "Thermals",
            subtitle: ThermalPressure.description,
            value: sensors.chipTemperature?.temperatureFormatted ?? "—",
            // 20 °C is an idle room, 110 °C is where the chip throttles.
            fraction: sensors.chipTemperature.map { ($0 - 20) / 90 } ?? 0,
            tint: .orange
        ) {
            SeriesChart(
                title: "Chip temperature",
                points: history,
                series: [ChartSeries(name: "Chip", tint: .yellow) { $0.temperature }],
                tint: .orange,
                domain: 20...110,
                label: { "\(Int($0))°" }
            )
            .frame(height: 280)

            HStack(alignment: .top) {
                StatValue(title: "Chip average", value: sensors.chipTemperature?.temperatureFormatted ?? "—")
                StatValue(title: "Hottest sensor", value: sensors.chipTemperatureMax?.temperatureFormatted ?? "—")
                StatValue(title: "SSD", value: sensors.ssdTemperature?.temperatureFormatted ?? "—")
                StatValue(title: "Battery", value: sensors.batteryTemperature?.temperatureFormatted ?? "—")
            }

            PropertyGrid(properties: sensors.fanSpeeds.isEmpty
                ? [("Fans", "None reported")]
                : sensors.fanSpeeds.enumerated().map {
                    ("Fan \($0.offset + 1)", "\(Int($0.element.rounded())) rpm")
                })
        }
    }
}
