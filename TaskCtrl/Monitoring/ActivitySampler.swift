import Darwin
import Foundation
import IOKit

/// Network and disk throughput plus how hard the system is being pushed.
struct ActivityReadings: Sendable, Equatable {
    /// Bytes per second.
    var networkIn: Double = 0
    var networkOut: Double = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0

    /// One-minute load average: how many threads want a core at once.
    var loadAverage: Double = 0
    var memoryPressure: MemoryPressure = .normal

    enum MemoryPressure: Sendable {
        case normal, warning, critical
    }
}

/// Turns cumulative byte counters into rates. Not thread-safe; `SystemSampler`
/// keeps it inside its actor.
final class ActivitySampler {
    private var lastTime: ContinuousClock.Instant?
    private var lastNetwork: [String: (received: UInt32, sent: UInt32)] = [:]
    private var lastDisk: (read: UInt64, written: UInt64)?

    func sample() -> ActivityReadings {
        var readings = ActivityReadings()

        let now = ContinuousClock.now
        let seconds = lastTime.map { now - $0 }.map {
            Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
        }
        lastTime = now

        let network = networkCounters()
        let disk = diskCounters()
        if let seconds, seconds > 0 {
            for (name, current) in network {
                guard let previous = lastNetwork[name] else { continue }
                // The kernel keeps these as 32-bit counters; &- handles the wrap.
                readings.networkIn += Double(current.received &- previous.received) / seconds
                readings.networkOut += Double(current.sent &- previous.sent) / seconds
            }
            if let disk, let previous = lastDisk,
               disk.read >= previous.read, disk.written >= previous.written {
                readings.diskRead = Double(disk.read - previous.read) / seconds
                readings.diskWrite = Double(disk.written - previous.written) / seconds
            }
        }
        lastNetwork = network
        lastDisk = disk

        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) > 0 { readings.loadAverage = load[0] }

        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            readings.memoryPressure = switch level {
            case 4: .critical
            case 2: .warning
            default: .normal
            }
        }
        return readings
    }

    /// Byte counters of the physical interfaces (Wi-Fi, Ethernet). Tunnels and
    /// bridges are skipped: their traffic also crosses a physical interface
    /// and would be counted twice.
    private func networkCounters() -> [String: (received: UInt32, sent: UInt32)] {
        var counters: [String: (received: UInt32, sent: UInt32)] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return counters }
        defer { freeifaddrs(list) }

        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data
            else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            counters[name] = (stats.ifi_ibytes, stats.ifi_obytes)
        }
        return counters
    }

    /// Total bytes read and written across all storage drivers since boot.
    private func diskCounters() -> (read: UInt64, written: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var written: UInt64 = 0
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let statistics = IORegistryEntryCreateCFProperty(
                service, "Statistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }
            read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            found = true
        }
        return found ? (read, written) : nil
    }
}
