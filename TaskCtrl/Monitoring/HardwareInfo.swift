import Foundation
import IOKit

/// Facts about this Mac that do not change while the app runs.
struct HardwareInfo: Sendable {
    enum CoreKind: Sendable {
        case performance, efficiency
    }

    static let shared = HardwareInfo()

    let chipName: String
    let modelIdentifier: String
    let physicalCores: Int
    let logicalCores: Int
    /// Kind of each logical CPU, indexed the way the kernel numbers them.
    let coreKinds: [CoreKind]
    /// Bytes; nil when the system does not report the value.
    let performanceL1Cache: UInt64?
    let performanceL2Cache: UInt64?
    let efficiencyL1Cache: UInt64?
    let efficiencyL2Cache: UInt64?
    let gpuName: String?
    let gpuCores: Int?
    let ssdModel: String?
    let bootDate: Date?

    var performanceCores: Int { coreKinds.count { $0 == .performance } }
    var efficiencyCores: Int { coreKinds.count { $0 == .efficiency } }

    private init() {
        chipName = Self.string("machdep.cpu.brand_string") ?? "Unknown"
        modelIdentifier = Self.string("hw.model") ?? "Unknown"
        physicalCores = Self.integer("hw.physicalcpu").map(Int.init) ?? 0
        logicalCores = Self.integer("hw.logicalcpu").map(Int.init)
            ?? ProcessInfo.processInfo.activeProcessorCount

        // Level 0 is the performance cluster, level 1 the efficiency one.
        // L1 is split into data and instruction halves; report them together.
        performanceL1Cache = Self.sum("hw.perflevel0.l1dcachesize", "hw.perflevel0.l1icachesize")
        performanceL2Cache = Self.integer("hw.perflevel0.l2cachesize")
        efficiencyL1Cache = Self.sum("hw.perflevel1.l1dcachesize", "hw.perflevel1.l1icachesize")
        efficiencyL2Cache = Self.integer("hw.perflevel1.l2cachesize")

        coreKinds = Self.readCoreKinds(logicalCores: logicalCores)

        let gpu = Self.properties(ofFirst: "IOAccelerator")
        gpuName = gpu?["model"] as? String
        gpuCores = (gpu?["gpu-core-count"] as? NSNumber)?.intValue
        ssdModel = (Self.properties(ofFirst: "IONVMeController")?["Model Number"] as? String)?
            .trimmingCharacters(in: .whitespaces)

        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 {
            bootDate = Date(timeIntervalSince1970: Double(boot.tv_sec))
        } else {
            bootDate = nil
        }
    }

    // MARK: - Core layout

    /// The device tree marks every CPU as "E" or "P". If that cannot be read,
    /// fall back to the Apple Silicon convention: efficiency cores come first.
    private static func readCoreKinds(logicalCores: Int) -> [CoreKind] {
        var kinds = [CoreKind?](repeating: nil, count: logicalCores)

        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if cpus != 0 {
            defer { IOObjectRelease(cpus) }
            var iterator: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(cpus, "IODeviceTree", &iterator) == KERN_SUCCESS {
                defer { IOObjectRelease(iterator) }
                while case let cpu = IOIteratorNext(iterator), cpu != 0 {
                    defer { IOObjectRelease(cpu) }
                    guard let index = (property("logical-cpu-id", of: cpu) as? NSNumber)?.intValue,
                          kinds.indices.contains(index),
                          let type = property("cluster-type", of: cpu) as? Data,
                          let letter = type.first
                    else { continue }
                    kinds[index] = letter == UInt8(ascii: "E") ? .efficiency : .performance
                }
            }
        }

        if kinds.contains(where: { $0 == nil }) {
            let efficient = integer("hw.perflevel1.logicalcpu").map(Int.init) ?? 0
            return (0..<logicalCores).map { $0 < efficient ? .efficiency : .performance }
        }
        return kinds.compactMap { $0 }
    }

    // MARK: - Helpers

    private static func integer(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func sum(_ first: String, _ second: String) -> UInt64? {
        guard let a = integer(first), let b = integer(second) else { return nil }
        return a + b
    }

    private static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func properties(ofFirst className: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }
}
