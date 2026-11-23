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

    private enum Mode: String {
        case overall, engines
    }

    @AppStorage("gpuChartMode") private var mode: Mode = .overall

    var body: some View {
        let sensors = snapshot.sensors
        let hardware = HardwareInfo.shared
        let memory = "\(sensors.gpuMemory?.memoryFormatted ?? "—") / \(snapshot.memory.total.memoryFormatted)"

        DetailPage(
            title: "GPU",
            subtitle: [hardware.gpuName, hardware.gpuCores.map { "\($0) cores" }]
                .compactMap { $0 }.joined(separator: " · "),
            value: sensors.gpuUtilization?.percentFormatted ?? "—",
            fraction: sensors.gpuUtilization ?? 0,
            tint: .cyan
        ) {
            HStack {
                Text(mode == .overall ? "% Utilization" : "% Utilization by engine")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Utilization chart", selection: $mode) {
                    Text("Overall").tag(Mode.overall)
                    Text("Engines").tag(Mode.engines)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Group {
                switch mode {
                case .overall:
                    SeriesChart(
                        title: "Utilization",
                        points: history,
                        series: [ChartSeries(name: "Utilization", tint: .green) { $0.gpu }],
                        tint: .cyan
                    )
                case .engines:
                    HStack(spacing: 12) {
                        MiniChart(
                            title: "Renderer",
                            value: sensors.gpuRenderer?.percentFormatted ?? "—",
                            points: history,
                            series: ChartSeries(name: "Renderer", tint: .green) { $0.gpuRenderer }
                        )
                        MiniChart(
                            title: "Tiler",
                            value: sensors.gpuTiler?.percentFormatted ?? "—",
                            points: history,
                            series: ChartSeries(name: "Tiler", tint: .green) { $0.gpuTiler }
                        )
                    }
                }
            }
            .frame(height: 220)

            MiniChart(
                title: "GPU memory in use",
                value: memory,
                points: history,
                series: ChartSeries(name: "Memory", tint: .blue) { $0.gpuMemory },
                domain: 0...Double(max(snapshot.memory.total, 1))
            )
            .frame(height: 110)

            // The blocks that work on video; the Apple Silicon tab has all of them.
            let video = sensors.mediaEngines.filter { [.videoEncode, .videoDecode, .scaler].contains($0.kind) }
            if !video.isEmpty {
                mediaEngines(video)
            }

            HStack(alignment: .top) {
                StatValue(title: "Utilization", value: sensors.gpuUtilization?.percentFormatted ?? "—")
                StatValue(title: "Memory usage", value: memory)
                StatValue(title: "Power", value: sensors.gpuPower?.powerFormatted ?? "—")
                StatValue(title: "Temperature", value: temperature(sensors)?.temperatureFormatted ?? "—")
            }
        }
    }

    /// Two charts to a row.
    private func mediaEngines(_ engines: [MediaEngineReading]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Media engine active residency")
                .font(.callout)
                .foregroundStyle(.secondary)
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(Array(stride(from: 0, to: engines.count, by: 2)), id: \.self) { first in
                    GridRow {
                        ForEach(first..<min(first + 2, engines.count), id: \.self) { index in
                            MiniChart(
                                title: "\(engines[index].name) active",
                                value: engines[index].active.percentFormatted,
                                points: history,
                                series: ChartSeries(name: engines[index].name, tint: .green) {
                                    $0.mediaEngines[engines[index].name]
                                }
                            )
                            .frame(height: 100)
                        }
                    }
                }
            }
            Text("Active residency is time above the idle voltage floor: the engine was in use, not how much of it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The GPU's own sensors where the Mac names them, the chip otherwise.
    private func temperature(_ sensors: SensorReadings) -> Double? {
        let own = sensors.temperatures.filter { $0.name.localizedCaseInsensitiveContains("gpu") }.map(\.value)
        return own.isEmpty ? sensors.chipTemperature : own.reduce(0, +) / Double(own.count)
    }
}

// MARK: - NPU

struct NPUDetail: View {
    let snapshot: SystemSnapshot
    let history: [HistoryPoint]

    var body: some View {
        let engine = snapshot.sensors.neuralEngine
        let hardware = HardwareInfo.shared
        let facts = [
            hardware.neuralEngineCores.map { "\($0) cores" },
            hardware.neuralEngineArchitecture,
        ].compactMap { $0 }

        DetailPage(
            title: "NPU",
            subtitle: (["Apple Neural Engine"]
                + (engine.map { ["\($0.blocks) hardware block\($0.blocks == 1 ? "" : "s")"] } ?? [])
                + facts).joined(separator: " · "),
            value: engine?.active.percentFormatted ?? "—",
            fraction: engine?.active ?? 0,
            tint: .orange
        ) {
            SeriesChart(
                title: "Powered Neural Engine blocks",
                points: history,
                series: [ChartSeries(name: "Powered", tint: .yellow) { $0.neuralEngine }],
                tint: .orange
            )
            .frame(height: 300)

            HStack(alignment: .top) {
                StatValue(title: "Blocks powered", value: engine?.active.percentFormatted ?? "—")
                StatValue(title: "Power draw", value: engine?.power?.powerFormatted ?? "—")
                StatValue(
                    title: "Interval energy",
                    value: engine?.energy.map { "\(($0 * 1000).formatted(.number.precision(.fractionLength(0)))) mJ" } ?? "—"
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text((["ANE"] + facts).joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(state(engine))
                    .font(.title3.weight(.semibold))
            }

            Label {
                Text(note(engine))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func state(_ engine: NeuralEngineReadings?) -> String {
        guard let engine else { return "Unavailable" }
        // Powered for most of the last second.
        return engine.active >= 0.5 ? "Powered on" : "Power gated"
    }

    private func note(_ engine: NeuralEngineReadings?) -> String {
        guard let engine else { return "This Mac reports no Neural Engine." }
        var note = "Blocks powered is the share of the time the Neural Engine was not power gated; it is not compute utilization. The system keeps it on for a few seconds after its last job."
        if engine.power == nil {
            note += " Power and energy counters are unavailable on this Mac."
        }
        return note
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
