import SwiftUI

struct SummaryView: View {
    @Environment(SystemMonitor.self) private var monitor
    /// The moment or stretch of the CPU chart being looked back at; nil while live.
    @State private var selection: ClosedRange<Date>?

    var body: some View {
        let snapshot = monitor.snapshot
        let history = monitor.history
        let inspection = selection.flatMap { HistoryInspection(range: $0, history: history) }

        ScrollView {
            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    SystemMetersPanel(snapshot: snapshot, powerCeiling: powerCeiling(history))
                        .frame(width: 250)
                    CPUOverviewPanel(
                        snapshot: snapshot, history: history, inspection: inspection, selection: $selection
                    )
                    TopProcessesPanel(
                        title: inspection.map { $0.isMoment ? nil : "Average CPU use" } ?? nil,
                        processes: inspection?.processes ?? snapshot.processes,
                        // Only needed to mark what has quit since.
                        running: inspection == nil ? nil : Set(snapshot.processes.map(\.pid))
                    )
                    .frame(width: 350)
                }
                .frame(height: 360)

                MemoryPanel(memory: snapshot.memory, history: history)
                    .frame(height: 190)

                HStack(spacing: 14) {
                    NetworkTile(activity: snapshot.activity)
                    DiskTile(activity: snapshot.activity)
                    FansTile(speeds: snapshot.sensors.fanSpeeds)
                    NeuralEngineTile(readings: snapshot.sensors.neuralEngine)
                    PressureTile(snapshot: snapshot)
                }
                .frame(height: 104)
            }
            .padding(16)
        }
        .background(Dashboard.pageFill)
        .navigationTitle("Summary")
        .onChange(of: snapshot.date) {
            // Back to live once the selection has scrolled off the chart.
            if let selection, selection.upperBound < Date().addingTimeInterval(-ScrollingChart.span - 2) {
                self.selection = nil
            }
        }
    }

    /// Meter and chart top that fits the recent peak, in steps of 20 W so it does not jitter.
    private func powerCeiling(_ history: [HistoryPoint]) -> Double {
        let peak = history.compactMap(\.power).max() ?? 0
        return max(20, (peak / 20).rounded(.up) * 20)
    }
}

// MARK: - Looking back

/// What the samples under a selection on the CPU chart add up to.
private struct HistoryInspection {
    let range: ClosedRange<Date>
    /// The samples covered; for a single moment, the one nearest to it.
    let points: [HistoryPoint]

    var isMoment: Bool { range.lowerBound == range.upperBound }

    init?(range: ClosedRange<Date>, history: [HistoryPoint]) {
        var covered = range.lowerBound == range.upperBound ? [] : history.filter { range.contains($0.date) }
        if covered.isEmpty {
            let middle = range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) / 2)
            guard let nearest = history.min(by: {
                abs($0.date.timeIntervalSince(middle)) < abs($1.date.timeIntervalSince(middle))
            }) else { return nil }
            covered = [nearest]
        }
        self.range = range
        points = covered
    }

    var cpu: Double { points.reduce(0) { $0 + $1.cpu } / Double(points.count) }
    var kernel: Double { points.reduce(0) { $0 + $1.kernel } / Double(points.count) }

    /// Processes with their CPU use averaged over the samples. A process
    /// absent from a sample counts as idle in it.
    var processes: [ProcessSample] {
        guard points.count > 1 else { return points.first?.topProcesses ?? [] }
        var latest: [pid_t: ProcessSample] = [:]
        var totals: [pid_t: Double] = [:]
        for point in points {
            for process in point.topProcesses {
                latest[process.pid] = process
                totals[process.pid, default: 0] += process.cpu
            }
        }
        return latest.values.map { process in
            var averaged = process
            averaged.cpu = (totals[process.pid] ?? 0) / Double(points.count)
            return averaged
        }
    }

    var caption: String {
        let time = Date.FormatStyle(date: .omitted, time: .standard)
        guard points.count > 1, let first = points.first, let last = points.last else {
            return points.first.map { "At \($0.date.formatted(time))" } ?? ""
        }
        let seconds = Int(last.date.timeIntervalSince(first.date).rounded())
        return "\(first.date.formatted(time)) – \(last.date.formatted(time)) · \(seconds) s"
    }
}

// MARK: - System meters

/// Four level meters side by side: CPU, power, temperature, GPU.
private struct SystemMetersPanel: View {
    let snapshot: SystemSnapshot
    let powerCeiling: Double

    var body: some View {
        let sensors = snapshot.sensors

        Panel(tint: .cyan) {
            VStack(spacing: 12) {
                PanelHeader(
                    title: "Sys",
                    value: sensors.systemPower?.powerFormatted ?? "",
                    tint: .cyan
                )
                HStack(spacing: 12) {
                    meter("CPU", snapshot.cpu.total.percentFormatted, snapshot.cpu.total, .green)
                    meter(
                        "Power",
                        sensors.systemPower?.powerFormatted,
                        sensors.systemPower.map { $0 / powerCeiling },
                        .red
                    )
                    meter(
                        "Temp",
                        sensors.chipTemperature?.temperatureFormatted,
                        // 20 °C is an idle room, 110 °C is where the chip throttles.
                        sensors.chipTemperature.map { ($0 - 20) / 90 },
                        .yellow
                    )
                    meter(
                        "GPU",
                        sensors.gpuUtilization?.percentFormatted,
                        sensors.gpuUtilization,
                        .blue
                    )
                }
            }
        }
    }

    private func meter(_ title: String, _ value: String?, _ fraction: Double?, _ tint: Color) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            SegmentMeter(fraction: fraction ?? 0, tint: tint)
            Text(value ?? "—")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - CPU overview

/// Utilization, kernel share and chip temperature on one time axis.
private struct CPUOverviewPanel: View {
    let snapshot: SystemSnapshot
    let history: [HistoryPoint]
    let inspection: HistoryInspection?
    @Binding var selection: ClosedRange<Date>?

    /// Top of the temperature scale on the right-hand axis, °C.
    private static let temperatureScale = 110.0

    var body: some View {
        Panel(tint: .green) {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(
                    title: inspection == nil ? "CPU overview" : "CPU history",
                    value: (inspection?.cpu ?? snapshot.cpu.total).percentFormatted,
                    tint: .green
                )
                HStack(spacing: 16) {
                    legend("Utilization", .green)
                    legend("Temperature", .orange)
                    legend("Kernel", .red)
                    Spacer(minLength: 0)
                    if inspection != nil {
                        Button("Live", systemImage: "xmark.circle.fill") { selection = nil }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .keyboardShortcut(.cancelAction)
                            .help("Back to the live view (Esc)")
                    }
                }
                chart
                Text(footer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var chart: some View {
        HStack(spacing: 6) {
            AxisLabels(labels: ["100%", "50%", "0%"], tint: .green, alignment: .trailing)
            ScrollingChart(
                lines: [
                    .init(tint: .orange, points: history.compactMap { point in
                        point.temperature.map { .init(date: point.date, value: $0 / Self.temperatureScale) }
                    }),
                    .init(tint: .red, points: history.map { .init(date: $0.date, value: $0.kernel) }),
                    .init(tint: .green, points: history.map { .init(date: $0.date, value: $0.cpu) }),
                ],
                tint: .green,
                selection: selection,
                onSelect: { selection = $0 }
            )
            AxisLabels(
                labels: ["\(Int(Self.temperatureScale))°", "\(Int(Self.temperatureScale / 2))°", "0°"],
                tint: .orange,
                alignment: .leading
            )
        }
    }

    private var footer: String {
        if let inspection {
            return "\(inspection.caption) · CPU \(inspection.cpu.percentFormatted) · Kernel \(inspection.kernel.percentFormatted)"
        }
        var parts = ["\(ProcessInfo.processInfo.activeProcessorCount) cores"]
        parts.append("User \(snapshot.cpu.user.percentFormatted)")
        parts.append("Kernel \(snapshot.cpu.system.percentFormatted)")
        // What the kernel bills to processes: the closest available figure
        // for CPU power, since the chip-level counter reads zero.
        if snapshot.processPower > 0 {
            parts.append("Processes \(snapshot.processPower.powerFormatted)")
        }
        return parts.joined(separator: " · ")
    }

    private func legend(_ title: String, _ tint: Color) -> some View {
        Text(title)
            .font(.callout.weight(.medium))
            .foregroundStyle(tint)
    }
}

// MARK: - Top processes

private struct TopProcessesPanel: View {
    /// Replaces the usual "Top N" heading.
    var title: String?
    let processes: [ProcessSample]
    /// PIDs alive right now, when showing the past; rows missing from it are dimmed.
    var running: Set<pid_t>?

    private static let rowCount = 12

    private var top: [ProcessSample] { processes.busiest(Self.rowCount) }

    /// False for the first moments, so the initial fill doesn't flash every row.
    @State private var hasSettled = false

    var body: some View {
        let top = top
        Panel(tint: .cyan) {
            VStack(alignment: .leading, spacing: 8) {
                PanelHeader(title: title ?? "Top \(Self.rowCount) CPU processes", tint: .cyan)
                VStack(spacing: 2) {
                    HStack(spacing: 8) {
                        Text("PID").frame(width: TopProcessRow.pidWidth, alignment: .trailing)
                        Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                        Text("CPU").frame(width: TopProcessRow.cpuWidth, alignment: .trailing)
                        Text("Memory").frame(width: TopProcessRow.memoryWidth, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)

                    ForEach(Array(top.enumerated()), id: \.element.pid) { rank, process in
                        TopProcessRow(
                            process: process,
                            rank: rank,
                            flashesOnAppear: hasSettled,
                            hasQuit: running.map { !$0.contains(process.pid) } ?? false
                        )
                    }
                }
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(2))
            hasSettled = true
        }
    }
}

private struct TopProcessRow: View {
    let process: ProcessSample
    let rank: Int
    let flashesOnAppear: Bool
    /// The process was running at the moment shown but is gone now.
    var hasQuit = false

    static let pidWidth = 42.0
    static let cpuWidth = 44.0
    static let memoryWidth = 66.0

    /// Bumped when the row climbs or enters the list; the background flashes on each change.
    @State private var flashes = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: String(process.pid))
                .foregroundStyle(.secondary)
                .frame(width: Self.pidWidth, alignment: .trailing)
            HStack(spacing: 6) {
                ProcessIcon(path: process.path)
                Text(process.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(process.hasStats ? (process.cpu / 100).percentFormatted : "—")
                .foregroundStyle(.green)
                .frame(width: Self.cpuWidth, alignment: .trailing)
            Text(process.hasStats ? process.memory.memoryFormatted : "—")
                .frame(width: Self.memoryWidth, alignment: .trailing)
        }
        .font(.callout.monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 4)
        .frame(height: 19)
        .opacity(hasQuit ? 0.5 : 1)
        .background(
            FlashBackground(
                tint: hasQuit ? .red : .green,
                base: hasQuit ? 0.14 : (rank.isMultiple(of: 2) ? 0 : 0.07),
                trigger: flashes
            )
        )
        .help(hasQuit ? "\(process.name) is no longer running" : "")
        .onChange(of: rank) { old, new in
            if new < old { flashes += 1 }
        }
        .onAppear {
            if flashesOnAppear { flashes += 1 }
        }
    }
}

// MARK: - Memory

private struct MemoryPanel: View {
    let memory: MemoryUsage
    let history: [HistoryPoint]

    private static let gigabyte = 1_073_741_824.0

    /// Used memory in GB over time.
    private var series: [(date: Date, value: Double)] {
        history.map { ($0.date, $0.memory * Double(memory.total) / Self.gigabyte) }
    }

    /// The line barely moves against the full 0...total range, so zoom in on
    /// the recent span with a little headroom.
    private var domain: ClosedRange<Double> {
        let values = series.map(\.value)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let padding = max((high - low) * 0.15, 0.1)
        return max(low - padding, 0)...(high + padding)
    }

    var body: some View {
        Panel(tint: .purple) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 6) {
                    SegmentMeter(fraction: memory.fraction, tint: .purple, segments: 14)
                        .frame(width: 44)
                    Text(memory.fraction.percentFormatted)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.purple)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Memory utilization")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text("\(memory.used.memoryFormatted) / \(memory.total.memoryFormatted)")
                            .font(.headline.monospacedDigit())
                    }
                    chart
                    HStack {
                        Text("Available \((memory.total > memory.used ? memory.total - memory.used : 0).memoryFormatted)")
                        Spacer()
                        Text("Cached \(memory.cached.memoryFormatted)")
                        Spacer()
                        Text("Swap \(memory.swapUsed == 0 ? "0" : memory.swapUsed.memoryFormatted)")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var chart: some View {
        let domain = domain
        let span = max(domain.upperBound - domain.lowerBound, 0.001)
        return HStack(spacing: 6) {
            AxisLabels(
                labels: [domain.upperBound, domain.lowerBound].map {
                    "\($0.formatted(.number.precision(.fractionLength(1)))) GB"
                },
                tint: .purple,
                alignment: .trailing
            )
            ScrollingChart(
                lines: [.init(tint: .purple, points: series.map {
                    .init(date: $0.date, value: ($0.value - domain.lowerBound) / span)
                })],
                tint: .purple
            )
        }
    }
}

// MARK: - Bottom tiles

/// Places a rate on a logarithmic 0...1 scale, so both a trickle and a flood
/// are visible: `floor` lights nothing, `ceiling` lights everything.
private func logFraction(_ value: Double, floor: Double, ceiling: Double) -> Double {
    guard value > floor else { return 0 }
    return min(log(value / floor) / log(ceiling / floor), 1)
}

private struct NetworkTile: View {
    let activity: ActivityReadings

    var body: some View {
        let total = activity.networkIn + activity.networkOut
        StatTile(
            title: "Network",
            symbol: "network",
            value: total.rateFormatted,
            detail: "↓ \(activity.networkIn.rateFormatted) · ↑ \(activity.networkOut.rateFormatted)",
            // 1 kB/s to 100 MB/s.
            fraction: logFraction(total, floor: 1_000, ceiling: 100_000_000),
            tint: .blue
        )
    }
}

private struct DiskTile: View {
    let activity: ActivityReadings

    var body: some View {
        let total = activity.diskRead + activity.diskWrite
        StatTile(
            title: "Disk",
            symbol: "internaldrive",
            value: total.rateFormatted,
            detail: "R \(activity.diskRead.rateFormatted) · W \(activity.diskWrite.rateFormatted)",
            // 10 kB/s to 2 GB/s.
            fraction: logFraction(total, floor: 10_000, ceiling: 2_000_000_000),
            tint: .green
        )
    }
}

private struct FansTile: View {
    let speeds: [Double]

    /// Roughly the top speed of MacBook Pro fans; only scales the meter.
    private static let fullSpeed = 6_000.0

    var body: some View {
        let fastest = speeds.max()
        StatTile(
            title: "Fans",
            symbol: "fan",
            value: fastest.map { "\(Int($0.rounded())) rpm" } ?? "—",
            detail: speeds.isEmpty
                ? "This Mac reports no fans"
                : speeds.enumerated()
                    .map { "Fan \($0.offset + 1): \(Int($0.element.rounded()))" }
                    .joined(separator: " · "),
            fraction: (fastest ?? 0) / Self.fullSpeed,
            tint: .orange
        )
    }
}

private struct NeuralEngineTile: View {
    let readings: NeuralEngineReadings?

    var body: some View {
        StatTile(
            title: "NPU",
            symbol: "brain",
            value: readings.map(\.active.percentFormatted) ?? "—",
            detail: detail,
            fraction: readings?.active ?? 0,
            tint: .yellow
        )
        .help("Share of the last second the Neural Engine was powered on. It stays on for a few seconds after its last job, so this is not how hard it is working.")
    }

    private var detail: String {
        guard let readings else { return "No Neural Engine reading" }
        var parts = ["Neural Engine powered on"]
        if readings.blocks > 1 { parts.insert("\(readings.blocks) blocks", at: 0) }
        if let power = readings.power { parts.append(power.powerFormatted) }
        return parts.joined(separator: " · ")
    }
}
