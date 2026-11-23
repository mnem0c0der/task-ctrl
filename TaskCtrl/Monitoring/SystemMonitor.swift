import Foundation
import Observation

/// Publishes the latest system snapshot to the UI once per interval.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var snapshot = SystemSnapshot()
    private(set) var history: [HistoryPoint] = []
    /// Process list for the big table, refreshed on every second sample.
    /// Redrawing ~900 rows is the most expensive thing the app does, and a
    /// table that reshuffles every second is hard to read anyway. Views that
    /// read only this property are not redrawn by the faster `snapshot`.
    private(set) var tableProcesses: [ProcessSample] = []
    /// Processes that quit within the last few table refreshes, as they
    /// last were. The table keeps showing them for a moment, so a row does
    /// not just vanish.
    private(set) var exitedProcesses: [ProcessSample] = []

    let interval: Duration = .seconds(1)
    let historyLimit = 120

    private let sampler = SystemSampler()
    /// Lowest and highest value of every sensor reading since launch or the
    /// last reset, keyed by `SensorNode.id`.
    private(set) var sensorRanges: [String: (min: Double, max: Double)] = [:]

    private var task: Task<Void, Never>?
    private var sampleCount = 0

    /// What the table needs to remember about a process between refreshes.
    private struct ProcessTrend {
        var smoothedCPU: Double
        /// The figures as the table rounds them, to tell when they change.
        var cpuShown: Int
        var memoryShown: UInt64
        var cpuHeat = 0.0
        var memoryHeat = 0.0
    }

    private var trends: [pid_t: ProcessTrend] = [:]
    private var exiting: [(sample: ProcessSample, refreshesLeft: Int)] = []

    /// Share of the way the smoothed CPU moves to the new value on each
    /// refresh; with a refresh every two seconds it settles in about ten.
    private static let smoothing = 0.25
    /// What is left of a highlight after each refresh, and when it is gone.
    private static let cooling = 0.5
    private static let coldBelow = 0.2
    /// Highlight for the smallest change that shows on screen.
    private static let faintest = 0.3
    /// How many refreshes a process that quit stays listed.
    private static let exitedRefreshes = 3

    func start() {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                apply(await sampler.sample())
                try? await Task.sleep(for: interval)
            }
        }
    }

    func resetSensorRanges() {
        sensorRanges = [:]
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func apply(_ new: SystemSnapshot) {
        snapshot = new
        if sampleCount > 0 {
            // The very first sample has no rates yet (they need two reads),
            // and its zeros would stick as every minimum.
            for reading in SensorTree.build(from: new).flatMap(\.readings) {
                guard let value = reading.value else { continue }
                let known = sensorRanges[reading.id]
                sensorRanges[reading.id] = (
                    Swift.min(known?.min ?? value, value), Swift.max(known?.max ?? value, value)
                )
            }
        }
        if sampleCount % 2 == 0 || tableProcesses.isEmpty {
            refreshTable(with: new.processes)
        }
        sampleCount += 1
        history.append(
            HistoryPoint(
                date: new.date,
                cpu: new.cpu.total,
                kernel: new.cpu.system,
                memory: new.memory.fraction,
                gpu: new.sensors.gpuUtilization,
                gpuRenderer: new.sensors.gpuRenderer,
                gpuTiler: new.sensors.gpuTiler,
                gpuMemory: new.sensors.gpuMemory.map(Double.init),
                mediaEngines: Dictionary(
                    new.sensors.mediaEngines.map { ($0.name, $0.active) }, uniquingKeysWith: { first, _ in first }
                ),
                neuralEngine: new.sensors.neuralEngine?.active,
                temperature: new.sensors.chipTemperature,
                power: new.sensors.systemPower,
                performanceCores: new.cpu.performance,
                efficiencyCores: new.cpu.efficiency,
                cores: new.cpu.cores,
                networkIn: new.activity.networkIn,
                networkOut: new.activity.networkOut,
                diskRead: new.activity.diskRead,
                diskWrite: new.activity.diskWrite,
                topProcesses: new.processes.busiest(HistoryPoint.topProcessCount)
            )
        )
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    // MARK: - Process table

    /// Publishes the processes for the table with their smoothed CPU and
    /// change highlights, and keeps the ones that just quit for a moment.
    private func refreshTable(with processes: [ProcessSample]) {
        // The first samples have no rates yet; their jump from zero is not news.
        let highlights = sampleCount >= 4
        var next: [pid_t: ProcessTrend] = [:]
        next.reserveCapacity(processes.count)

        let annotated = processes.map { process in
            var process = process
            let cpuShown = Int((process.cpu * 10).rounded())
            let memoryShown = process.memory / Self.memoryStep(process.memory)
            var trend = trends[process.pid]
                ?? ProcessTrend(smoothedCPU: process.cpu, cpuShown: cpuShown, memoryShown: memoryShown)

            trend.smoothedCPU += (process.cpu - trend.smoothedCPU) * Self.smoothing
            // A big move lights the cell fully, a flicker in the last digit
            // only faintly: three points of CPU, or two percent of memory, is big.
            let cpuMove = Double(abs(cpuShown - trend.cpuShown)) / 30
            let memoryMove = Double(max(memoryShown, trend.memoryShown) - min(memoryShown, trend.memoryShown))
                / Double(max(memoryShown, 1)) / 0.02
            trend.cpuHeat = Self.heat(trend.cpuHeat, move: highlights ? cpuMove : 0)
            trend.memoryHeat = Self.heat(trend.memoryHeat, move: highlights ? memoryMove : 0)
            trend.cpuShown = cpuShown
            trend.memoryShown = memoryShown
            next[process.pid] = trend

            process.smoothedCPU = trend.smoothedCPU
            process.cpuHeat = trend.cpuHeat
            process.memoryHeat = trend.memoryHeat
            return process
        }

        // A pid can be reused; a process that is back is not an exited one.
        exiting = exiting.compactMap { entry in
            entry.refreshesLeft > 1 && next[entry.sample.pid] == nil
                ? (entry.sample, entry.refreshesLeft - 1) : nil
        }
        for var gone in tableProcesses where next[gone.pid] == nil {
            // It keeps its smoothed CPU, so it stays where it was in the list.
            gone.hasExited = true
            gone.cpu = 0
            gone.cpuHeat = 0
            gone.memoryHeat = 0
            gone.diskRead = 0
            gone.diskWrite = 0
            gone.networkIn = 0
            gone.networkOut = 0
            gone.power = 0
            exiting.append((gone, Self.exitedRefreshes))
        }

        trends = next
        tableProcesses = annotated
        exitedProcesses = exiting.map(\.sample)
    }

    /// The highlight after a refresh in which the figure moved by `move`,
    /// where 0 is no change on screen and 1 or more a big one.
    private static func heat(_ current: Double, move: Double) -> Double {
        let cooled = current * cooling
        let lit = move > 0 ? min(faintest + move * (1 - faintest), 1) : 0
        let heat = max(lit, cooled)
        return heat < coldBelow ? 0 : heat
    }

    /// The smallest change in memory the table's rounding shows:
    /// a tenth of a megabyte below a gigabyte, a hundredth of a gigabyte above.
    private static func memoryStep(_ bytes: UInt64) -> UInt64 {
        bytes < 1 << 30 ? (1 << 20) / 10 : (1 << 30) / 100
    }
}
