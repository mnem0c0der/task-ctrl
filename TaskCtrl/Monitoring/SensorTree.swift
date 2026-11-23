import Foundation

/// One line of the Sensors tab: a device, a group of readings, or a reading.
struct SensorNode: Identifiable, Sendable {
    enum Unit: Sendable {
        case watts, celsius, fraction, rpm, bytes, bytesPerSecond

        func format(_ value: Double) -> String {
            switch self {
            case .watts: value.powerFormatted
            case .celsius: value.temperatureFormatted
            case .fraction: value.percentFormatted
            case .rpm: "\(Int(value.rounded())) rpm"
            case .bytes: UInt64(max(value, 0)).memoryFormatted
            case .bytesPerSecond: value.rateFormatted
            }
        }
    }

    /// Path from the root, e.g. "cpu/temperatures/PMU tdie3". Stable across
    /// samples, so it keys both the min/max history and the expansion state.
    let id: String
    let name: String
    let symbol: String
    /// Nil for devices and groups, and while a sensor has no reading.
    var value: Double?
    var unit: Unit?
    var children: [SensorNode] = []

    var isReading: Bool { children.isEmpty }

    /// The reading a device or group shows on its own row: its first one.
    var headline: SensorNode? {
        isReading ? self : children.lazy.compactMap(\.headline).first
    }

    /// All readings below this node.
    var readings: [SensorNode] {
        isReading ? [self] : children.flatMap(\.readings)
    }
}

enum SensorTree {
    /// Builds the whole tree from one sample. Devices and groups with nothing
    /// to show on this Mac are left out.
    static func build(from snapshot: SystemSnapshot) -> [SensorNode] {
        let hardware = HardwareInfo.shared
        let sensors = snapshot.sensors
        let activity = snapshot.activity

        func reading(_ parent: String, _ name: String, _ symbol: String, _ value: Double?, _ unit: SensorNode.Unit) -> SensorNode? {
            guard let value else { return nil }
            return SensorNode(id: "\(parent)/\(name)", name: name, symbol: symbol, value: value, unit: unit)
        }
        func group(_ parent: String, _ name: String, _ symbol: String, _ children: [SensorNode?]) -> SensorNode? {
            let present = children.compactMap { $0 }
            guard !present.isEmpty else { return nil }
            return SensorNode(id: "\(parent)/\(name)", name: name, symbol: symbol, children: present)
        }
        func temperatures(_ parent: String, _ kind: TemperatureSensor.Kind, leading: [SensorNode?] = []) -> SensorNode? {
            let id = "\(parent)/Temperatures"
            return group(parent, "Temperatures", "thermometer.medium", leading + sensors.temperatures
                .filter { $0.kind == kind }
                .map { reading(id, $0.name, "thermometer.medium", $0.value, .celsius) })
        }

        var devices: [SensorNode?] = []

        // The Mac as a whole.
        devices.append(group("", "This Mac · \(hardware.modelIdentifier)", "desktopcomputer", [
            group("mac", "Powers", "bolt.fill", [
                reading("mac/Powers", "System total", "bolt.fill", sensors.systemPower, .watts),
                reading("mac/Powers", "Charger input", "bolt.fill", sensors.adapterPower, .watts),
            ]),
            temperatures("mac", .other),
            group("mac", "Fans", "fan", sensors.fanSpeeds.enumerated().map {
                reading("mac/Fans", "Fan \($0.offset + 1)", "fan", $0.element, .rpm)
            }),
        ]))

        // CPU.
        let coreKinds = hardware.coreKinds
        let cores: [SensorNode?] = snapshot.cpu.cores.enumerated().map { index, core in
            let efficient = coreKinds.indices.contains(index) && coreKinds[index] == .efficiency
            return reading(
                "cpu/Utilization", "Core \(efficient ? "E" : "P")\(index)", "gauge.with.dots.needle.33percent",
                core.total, .fraction
            )
        }
        devices.append(group("", hardware.chipName, "cpu", [
            temperatures("cpu", .chip, leading: [
                reading("cpu/Temperatures", "Chip average", "thermometer.medium", sensors.chipTemperature, .celsius),
                reading("cpu/Temperatures", "Hottest sensor", "thermometer.medium", sensors.chipTemperatureMax, .celsius),
            ]),
            group("cpu", "Powers", "bolt.fill", [
                reading("cpu/Powers", "CPU package", "bolt.fill", sensors.cpuPower, .watts),
                reading(
                    "cpu/Powers", "All processes", "bolt.fill",
                    snapshot.processPower > 0 ? snapshot.processPower : nil, .watts
                ),
            ]),
            group("cpu", "Utilization", "gauge.with.dots.needle.33percent", [
                reading("cpu/Utilization", "Total CPU", "gauge.with.dots.needle.33percent", snapshot.cpu.total, .fraction),
                reading("cpu/Utilization", "Kernel", "gauge.with.dots.needle.33percent", snapshot.cpu.system, .fraction),
                reading("cpu/Utilization", "Performance cores", "gauge.with.dots.needle.33percent", snapshot.cpu.performance.total, .fraction),
                reading("cpu/Utilization", "Efficiency cores", "gauge.with.dots.needle.33percent", snapshot.cpu.efficiency.total, .fraction),
            ] + cores),
        ]))

        // GPU.
        devices.append(group("", hardware.gpuName.map { "\($0) GPU" } ?? "GPU", "display", [
            group("gpu", "Utilization", "gauge.with.dots.needle.33percent", [
                reading("gpu/Utilization", "GPU", "gauge.with.dots.needle.33percent", sensors.gpuUtilization, .fraction),
            ]),
            group("gpu", "Powers", "bolt.fill", [
                reading("gpu/Powers", "GPU", "bolt.fill", sensors.gpuPower, .watts),
            ]),
            group("gpu", "Memory", "memorychip", [
                reading("gpu/Memory", "In use", "memorychip", sensors.gpuMemory.map(Double.init), .bytes),
            ]),
        ]))

        // Memory.
        devices.append(group("", "Memory", "memorychip", [
            group("memory", "Usage", "memorychip", [
                reading("memory/Usage", "In use", "memorychip", Double(snapshot.memory.used), .bytes),
                reading("memory/Usage", "App memory", "memorychip", Double(snapshot.memory.app), .bytes),
                reading("memory/Usage", "Wired", "memorychip", Double(snapshot.memory.wired), .bytes),
                reading("memory/Usage", "Compressed", "memorychip", Double(snapshot.memory.compressed), .bytes),
                reading("memory/Usage", "Cached", "memorychip", Double(snapshot.memory.cached), .bytes),
                reading("memory/Usage", "Swap used", "memorychip", Double(snapshot.memory.swapUsed), .bytes),
            ]),
        ]))

        // Storage.
        devices.append(group("", hardware.ssdModel ?? "Storage", "internaldrive", [
            temperatures("ssd", .ssd),
            group("ssd", "Activity", "arrow.up.arrow.down", [
                reading("ssd/Activity", "Read", "arrow.down", activity.diskRead, .bytesPerSecond),
                reading("ssd/Activity", "Write", "arrow.up", activity.diskWrite, .bytesPerSecond),
            ]),
        ]))

        // Battery.
        devices.append(group("", "Battery", "battery.75percent", [
            temperatures("battery", .battery),
        ]))

        // Network.
        devices.append(group("", "Network", "network", [
            group("network", "Throughput", "arrow.up.arrow.down", [
                reading("network/Throughput", "Receive", "arrow.down", activity.networkIn, .bytesPerSecond),
                reading("network/Throughput", "Send", "arrow.up", activity.networkOut, .bytesPerSecond),
            ]),
        ]))

        return devices.compactMap { $0 }
    }
}
