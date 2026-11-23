import Foundation
import IOKit

/// Temperature, power and GPU readings. Every field is optional: which
/// sensors exist differs between Mac models and macOS versions.
struct SensorReadings: Sendable, Equatable {
    /// Average and hottest of the chip's die sensors, °C.
    var chipTemperature: Double?
    var chipTemperatureMax: Double?
    var ssdTemperature: Double?
    var batteryTemperature: Double?

    /// Whole-system draw, watts.
    var systemPower: Double?
    /// Power coming in from the charger, watts.
    var adapterPower: Double?
    var gpuPower: Double?
    var cpuPower: Double?
    var fanSpeeds: [Double] = []
    /// Every temperature sensor the Mac reports, by name.
    var temperatures: [TemperatureSensor] = []

    /// 0...1.
    var gpuUtilization: Double?
    var gpuMemory: UInt64?
}

struct TemperatureSensor: Sendable, Equatable {
    enum Kind: Sendable {
        /// On the chip itself.
        case chip
        case ssd
        case battery
        /// Elsewhere on the board, e.g. power management.
        case other
    }

    let name: String
    let kind: Kind
    /// °C.
    let value: Double
}

/// Owns the handles to the sensor sources. Not thread-safe; `SystemSampler`
/// keeps it inside its actor.
final class SensorSampler {
    private let smc = SMC()
    private let temperatures = TemperatureReader()
    private let energy = EnergyReader()
    private let gpu = GPUReader()

    func sample() -> SensorReadings {
        var readings = SensorReadings()

        temperatures?.read(into: &readings)

        if let smc {
            readings.systemPower = smc.float("PSTR")
            // Reads a fraction of a watt of noise when no charger is connected.
            readings.adapterPower = smc.float("PDTR").flatMap { $0 > 0.5 ? $0 : nil }
            for index in 0..<4 {
                guard let speed = smc.float("F\(index)Ac") else { break }
                readings.fanSpeeds.append(speed)
            }
        }

        if let power = energy?.read() {
            readings.gpuPower = power.gpu
            readings.cpuPower = power.cpu
        }

        if let usage = gpu?.read() {
            readings.gpuUtilization = usage.utilization
            readings.gpuMemory = usage.memory
        }
        return readings
    }
}

// MARK: - Temperature

private final class TemperatureReader {
    private typealias Kind = TemperatureSensor.Kind

    // HID constants for thermal sensors: Apple vendor usage page, temperature
    // sensor usage, temperature event type and its "level" field.
    private static let usagePage = 0xff00
    private static let usage = 5
    private static let eventType: Int64 = 15
    private static let levelField: Int32 = 15 << 16

    private let client: IOHIDEventSystemClient
    private let sensors: [(name: String, kind: Kind, service: IOHIDServiceClient)]

    init?() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
        let matching = ["PrimaryUsagePage": Self.usagePage, "PrimaryUsage": Self.usage] as CFDictionary
        _ = IOHIDEventSystemClientSetMatching(client, matching)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []

        self.client = client
        self.sensors = services.compactMap { service in
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String
            else { return nil }
            return (name, Self.kind(forSensorNamed: name), service)
        }
        if sensors.isEmpty { return nil }
    }

    /// Sensor names vary by chip generation: "PMU tdie3", "pACC MTR Temp Sensor2",
    /// "SOC MTR Temp Sensor0", "NAND CH0 temp", "gas gauge battery" and so on.
    private static func kind(forSensorNamed name: String) -> Kind {
        let name = name.lowercased()
        if name.contains("nand") { return .ssd }
        if name.contains("battery") { return .battery }
        if name.contains("tdie") || name.contains("acc mtr") || name.contains("soc mtr")
            || name.contains("gpu mtr") { return .chip }
        return .other
    }

    func read(into readings: inout SensorReadings) {
        var values: [Kind: [Double]] = [:]
        // Several sensors can share a name (the Mac reports some twice);
        // those are averaged into one entry.
        var byName: [String: (kind: Kind, sum: Double, count: Int)] = [:]
        for sensor in sensors {
            guard let event = IOHIDServiceClientCopyEvent(sensor.service, Self.eventType, 0, 0) else {
                continue
            }
            let value = IOHIDEventGetFloatValue(event, Self.levelField)
            // Sensors that are powered down report zero or garbage.
            guard value > 0, value < 150 else { continue }
            values[sensor.kind, default: []].append(value)
            let entry = byName[sensor.name] ?? (sensor.kind, 0, 0)
            byName[sensor.name] = (entry.kind, entry.sum + value, entry.count + 1)
        }
        readings.temperatures = byName
            .map { TemperatureSensor(name: $0.key, kind: $0.value.kind, value: $0.value.sum / Double($0.value.count)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        func average(_ kind: Kind) -> Double? {
            guard let list = values[kind], !list.isEmpty else { return nil }
            return list.reduce(0, +) / Double(list.count)
        }
        readings.chipTemperature = average(.chip)
        readings.chipTemperatureMax = values[.chip]?.max()
        readings.ssdTemperature = average(.ssd)
        readings.batteryTemperature = average(.battery)
    }
}

// MARK: - GPU

private final class GPUReader {
    private let service: io_service_t

    init?() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        if service == 0 { return nil }
    }

    deinit {
        IOObjectRelease(service)
    }

    func read() -> (utilization: Double?, memory: UInt64?)? {
        guard let statistics = IORegistryEntryCreateCFProperty(
            service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any] else { return nil }

        let percent = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue
        let memory = (statistics["In use system memory"] as? NSNumber)?.uint64Value
        return (percent.map { min(max($0 / 100, 0), 1) }, memory)
    }
}
