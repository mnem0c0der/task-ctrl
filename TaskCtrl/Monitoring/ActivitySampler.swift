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

    /// The storage device that worked hardest over the last interval.
    var storage = StorageActivity()

    /// One-minute load average: how many threads want a core at once.
    var loadAverage: Double = 0
    var memoryPressure: MemoryPressure = .normal

    enum MemoryPressure: Sendable {
        case normal, warning, critical
    }
}

struct StorageActivity: Sendable, Equatable {
    /// Product name of the device, e.g. "APPLE SSD AP1024Z"; empty when unknown.
    var name = ""
    /// Bytes per second.
    var read: Double = 0
    var write: Double = 0
    /// Share of the interval the device spent serving requests, 0...1.
    var busy: Double = 0
    /// Average time one request took, seconds; zero when there were none.
    var latency: TimeInterval = 0
}

/// Turns cumulative byte counters into rates. Not thread-safe; `SystemSampler`
/// keeps it inside its actor.
final class ActivitySampler {
    private var lastTime: ContinuousClock.Instant?
    private var lastNetwork: [String: (received: UInt32, sent: UInt32)] = [:]
    private var lastDisks: [UInt64: DiskCounters] = [:]
    /// Product names by registry entry; nil for devices that are not counted.
    /// Neither changes while a device is attached.
    private var diskNames: [UInt64: String?] = [:]

    /// Cumulative figures of one storage driver since boot.
    private struct DiskCounters {
        var read: UInt64 = 0
        var written: UInt64 = 0
        /// Nanoseconds spent in requests, and how many requests there were.
        var time: UInt64 = 0
        var operations: UInt64 = 0
    }

    func sample() -> ActivityReadings {
        var readings = ActivityReadings()

        let now = ContinuousClock.now
        let seconds = lastTime.map { now - $0 }.map {
            Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
        }
        lastTime = now

        let network = networkCounters()
        let disks = diskCounters()
        if let seconds, seconds > 0 {
            for (name, current) in network {
                guard let previous = lastNetwork[name] else { continue }
                // The kernel keeps these as 32-bit counters; &- handles the wrap.
                readings.networkIn += Double(current.received &- previous.received) / seconds
                readings.networkOut += Double(current.sent &- previous.sent) / seconds
            }
        }
        readings.storage = storageActivity(disks, over: seconds, totals: &readings)
        lastNetwork = network
        lastDisks = disks

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

    /// Adds every device's throughput to `totals` and returns the figures of
    /// the one that was busiest. While all are idle that is the device that
    /// has worked most since boot, which is the startup disk in practice.
    private func storageActivity(
        _ disks: [UInt64: DiskCounters], over seconds: Double?, totals: inout ActivityReadings
    ) -> StorageActivity {
        var busiest = StorageActivity()
        var busiestRank: (Double, UInt64, UInt64)?

        for (id, current) in disks {
            var activity = StorageActivity(name: (diskNames[id] ?? nil) ?? "")
            var busyTime = 0.0
            if let seconds, seconds > 0, let previous = lastDisks[id],
               current.read >= previous.read, current.written >= previous.written,
               current.time >= previous.time, current.operations >= previous.operations {
                activity.read = Double(current.read - previous.read) / seconds
                activity.write = Double(current.written - previous.written) / seconds
                busyTime = Double(current.time - previous.time) / 1e9
                // Requests overlap on a fast drive, so their times can add up
                // to more than the interval.
                activity.busy = min(busyTime / seconds, 1)
                let operations = current.operations - previous.operations
                activity.latency = operations > 0 ? busyTime / Double(operations) : 0
                totals.diskRead += activity.read
                totals.diskWrite += activity.write
            }
            // The entry ID only makes the choice stable between equals.
            let rank = (busyTime, current.time, id)
            if busiestRank.map({ rank > $0 }) ?? true {
                busiestRank = rank
                busiest = activity
            }
        }
        return busiest
    }

    /// Counters of every physical storage device, keyed by registry entry ID.
    /// Disk images are left out: what they read and write lands on the device
    /// that holds the image file and would be counted twice.
    private func diskCounters() -> [UInt64: DiskCounters] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator
        ) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var disks: [UInt64: DiskCounters] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            if diskNames[id] == nil { diskNames[id] = .some(productName(of: service)) }
            guard case .some(.some) = diskNames[id],
                  let statistics = IORegistryEntryCreateCFProperty(
                      service, "Statistics" as CFString, kCFAllocatorDefault, 0
                  )?.takeRetainedValue() as? [String: Any]
            else { continue }

            func counter(_ key: String) -> UInt64 {
                (statistics[key] as? NSNumber)?.uint64Value ?? 0
            }
            disks[id] = DiskCounters(
                read: counter("Bytes (Read)"),
                written: counter("Bytes (Write)"),
                time: counter("Total Time (Read)") + counter("Total Time (Write)"),
                operations: counter("Operations (Read)") + counter("Operations (Write)")
            )
        }
        return disks
    }

    /// The name the device behind a storage driver reports for itself, empty
    /// when it reports none; nil for a disk image.
    private func productName(of service: io_registry_entry_t) -> String? {
        func inherited(_ key: String) -> [String: Any]? {
            IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            ) as? [String: Any]
        }
        let interconnect = inherited("Protocol Characteristics")?["Physical Interconnect"] as? String
        guard interconnect != "Virtual Interface" else { return nil }
        return (inherited("Device Characteristics")?["Product Name"] as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}
