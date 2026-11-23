import SwiftUI

extension SystemPressure.Level {
    var tint: Color {
        switch self {
        case .low: .green
        case .elevated: .yellow
        case .high: .orange
        case .critical: .red
        }
    }

    /// The meter's colours from empty to full, placed so each level's colour
    /// sits where that level starts.
    static let scale: [Color] = [.green, .green, .yellow, .orange, .red]
}

// MARK: - Tile

/// Bottom-row block with the overall pressure. Clicking it shows what the
/// figure is made of.
struct PressureTile: View {
    let snapshot: SystemSnapshot

    @Environment(SystemMonitor.self) private var monitor
    @State private var showsDetails = false

    var body: some View {
        let pressure = SystemPressure(activity: snapshot.activity, memory: snapshot.memory)
        let load = snapshot.activity.loadAverage.formatted(.number.precision(.fractionLength(1)))
        let memory = SystemPressure.Level(score: pressure.memory).label.lowercased()
        let busy = pressure.storage.formatted(.percent.precision(.fractionLength(0)))

        Button {
            showsDetails.toggle()
        } label: {
            StatTile(
                // Short, so that it fits next to "CRITICAL" in a narrow tile.
                title: "Pressure",
                symbol: "gauge.with.dots.needle.33percent",
                value: pressure.level.label.uppercased(),
                detail: "Queue \(load) · Memory \(memory) · I/O \(busy)",
                fraction: pressure.score,
                tint: pressure.level.tint,
                scale: SystemPressure.Level.scale
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Click to see what this is made of.")
        .accessibilityHint("Shows what the pressure figure is made of")
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            PressureDetails()
                .environment(monitor)
        }
    }
}

// MARK: - Details

/// The breakdown behind the tile. Reads the monitor itself, so it keeps
/// updating while it is open.
private struct PressureDetails: View {
    @Environment(SystemMonitor.self) private var monitor

    private static let contributorCount = 5

    var body: some View {
        let snapshot = monitor.snapshot
        let pressure = SystemPressure(activity: snapshot.activity, memory: snapshot.memory)

        ViewThatFits(in: .vertical) {
            content(snapshot, pressure)
            ScrollView { content(snapshot, pressure) }
        }
        .frame(width: 430)
        .frame(maxHeight: 740)
    }

    private func content(_ snapshot: SystemSnapshot, _ pressure: SystemPressure) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(pressure)
            Divider()
            signals(snapshot, pressure)
            Divider()
            kernelState(snapshot)
            Divider()
            contributors(snapshot.processes)
        }
        .padding(18)
    }

    // MARK: Header

    private func header(_ pressure: SystemPressure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("System pressure \(pressure.level.label.uppercased())")
                Spacer(minLength: 8)
                Text(pressure.score.percentFormatted)
                    .monospacedDigit()
                    .foregroundStyle(pressure.level.tint)
            }
            .font(.title2.weight(.bold))
            Text("Primary driver: \(pressure.primary.title)")
                .font(.headline)
            Text("TaskCtrl combines the three signals below; the highest score sets the card’s status.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Signals

    private func signals(_ snapshot: SystemSnapshot, _ pressure: SystemPressure) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(SystemPressure.Signal.allCases, id: \.self) { signal in
                SignalRow(
                    title: signal.title,
                    score: pressure.score(of: signal),
                    isPrimary: signal == pressure.primary,
                    caption: caption(for: signal, snapshot)
                )
            }
        }
    }

    private func caption(for signal: SystemPressure.Signal, _ snapshot: SystemSnapshot) -> String {
        switch signal {
        case .cpuQueue:
            let load = snapshot.activity.loadAverage.formatted(.number.precision(.fractionLength(1)))
            let processors = ProcessInfo.processInfo.activeProcessorCount
            let full = SystemPressure.fullQueuePerProcessor.formatted()
            return "\(load) load average ÷ \(processors) logical processors. Full at \(full) per processor."
        case .memory:
            let memory = snapshot.memory
            let limits = SystemPressure.memoryThresholds
            func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }
            return "\(memory.fraction.percentFormatted) of \(memory.total.memoryFormatted) in use. "
                + "Elevated at \(percent(limits.elevated)), high \(percent(limits.high)), "
                + "critical \(percent(limits.critical))."
        case .storage:
            let storage = snapshot.activity.storage
            let latency = (storage.latency * 1000).formatted(.number.precision(.fractionLength(1)))
            return [
                storage.name.isEmpty ? "Storage" : storage.name,
                "R \(storage.read.rateFormatted)",
                "W \(storage.write.rateFormatted)",
                "\(latency) ms",
            ].joined(separator: " · ")
        }
    }

    // MARK: Kernel state

    private func kernelState(_ snapshot: SystemSnapshot) -> some View {
        let state: (label: String, tint: Color) = switch snapshot.activity.memoryPressure {
        case .normal: ("Normal", .green)
        case .warning: ("Warning", .yellow)
        case .critical: ("Critical", .red)
        }
        let memory = snapshot.memory
        let available = memory.total > memory.used ? memory.total - memory.used : 0

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("macOS memory pressure")
                Spacer(minLength: 8)
                Text(state.label)
                    .foregroundStyle(state.tint)
            }
            .font(.headline)
            Text("This is the kernel’s own pressure state. It can be Normal while the memory score above is elevated; Warning or Critical raise that score.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 5) {
                memoryRow("App memory", memory.app)
                memoryRow("Wired", memory.wired)
                memoryRow("Compressed", memory.compressed)
                memoryRow("Available", available)
                memoryRow("Swap used", memory.swapUsed)
            }
            .font(.callout)
            .padding(.top, 2)
        }
    }

    private func memoryRow(_ title: String, _ bytes: UInt64) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(bytes.memoryFormatted)
                .monospacedDigit()
        }
    }

    // MARK: Contributors

    private func contributors(_ processes: [ProcessSample]) -> some View {
        let largest = processes
            .filter { $0.memory > 0 }
            .sorted { ($0.memory, $1.pid) > ($1.memory, $0.pid) }
            .prefix(Self.contributorCount)

        return VStack(alignment: .leading, spacing: 8) {
            Text("Top memory contributors now")
                .font(.headline)
            ForEach(largest) { process in
                HStack {
                    Text(process.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(process.memory.memoryFormatted)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}

/// One of the three signals: name, score, a bar and where the number comes from.
private struct SignalRow: View {
    let title: String
    let score: Double
    let isPrimary: Bool
    let caption: String

    var body: some View {
        let tint = SystemPressure.Level(score: score).tint

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.title3.weight(isPrimary ? .semibold : .regular))
                if isPrimary {
                    Text("PRIMARY")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                }
                Spacer(minLength: 8)
                Text(score.percentFormatted)
                    .font(.title3.monospacedDigit())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    // A sliver stays visible at zero, so the bar reads as a bar.
                    Capsule()
                        .fill(isPrimary ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                        .frame(width: max(proxy.size.width * score, 6))
                }
            }
            .frame(height: 7)
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
