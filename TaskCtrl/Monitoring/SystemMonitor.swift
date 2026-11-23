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

    let interval: Duration = .seconds(1)
    let historyLimit = 120

    private let sampler = SystemSampler()
    /// Lowest and highest value of every sensor reading since launch or the
    /// last reset, keyed by `SensorNode.id`.
    private(set) var sensorRanges: [String: (min: Double, max: Double)] = [:]

    private var task: Task<Void, Never>?
    private var sampleCount = 0

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
            tableProcesses = new.processes
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
}
