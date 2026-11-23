import Darwin
import Foundation

/// Reads raw counters from the kernel. Lives on its own actor so sampling
/// never blocks the main thread.
actor SystemSampler {
    private var lastCPUTicks: host_cpu_load_info?
    private var lastCoreTicks: [[UInt32]] = []
    private var lastUsage: [pid_t: ProcessUsageRecord] = [:]
    private let network = ProcessNetworkMonitor()
    private var lastProcessSampleTime: UInt64 = 0
    private let sensors = SensorSampler()
    private let activity = ActivitySampler()
    private var identityCache: [pid_t: Identity] = [:]
    private var userNames: [uid_t: String] = [:]

    func sample() async -> SystemSnapshot {
        // Figures for other users' processes, when the root helper is installed.
        let privileged = await HelperClient.shared.processUsage()
        network.start()
        return SystemSnapshot(
            date: Date(),
            cpu: sampleCPU(),
            memory: sampleMemory(),
            processes: sampleProcesses(privileged: privileged),
            sensors: sensors.sample(),
            activity: activity.sample()
        )
    }

    // MARK: - CPU

    private func sampleCPU() -> CPUUsage {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return CPUUsage() }
        defer { lastCPUTicks = info }
        guard let last = lastCPUTicks else { return CPUUsage() }

        // cpu_ticks is (user, system, idle, nice); counters wrap, hence &-.
        let user = Double(info.cpu_ticks.0 &- last.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- last.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- last.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- last.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return CPUUsage() }
        var usage = CPUUsage(user: (user + nice) / total, system: system / total)

        usage.cores = sampleCores()
        let kinds = HardwareInfo.shared.coreKinds
        if usage.cores.count == kinds.count {
            func average(_ kind: HardwareInfo.CoreKind) -> CPUUsage.Load {
                let group = zip(usage.cores, kinds).filter { $0.1 == kind }.map(\.0)
                guard !group.isEmpty else { return CPUUsage.Load() }
                return CPUUsage.Load(
                    user: group.reduce(0) { $0 + $1.user } / Double(group.count),
                    system: group.reduce(0) { $0 + $1.system } / Double(group.count)
                )
            }
            usage.performance = average(.performance)
            usage.efficiency = average(.efficiency)
        }
        return usage
    }

    /// Load of every logical CPU since the previous call.
    private func sampleCores() -> [CPUUsage.Load] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount
        ) == KERN_SUCCESS, let info else { return [] }
        // The kernel allocates this array in our address space; give it back.
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        // Four counters per CPU: user, system, idle, nice.
        let states = Int(CPU_STATE_MAX)
        let ticks = (0..<Int(cpuCount)).map { cpu in
            (0..<states).map { UInt32(bitPattern: info[cpu * states + $0]) }
        }
        defer { lastCoreTicks = ticks }
        guard lastCoreTicks.count == ticks.count else { return [] }

        return zip(ticks, lastCoreTicks).map { now, before in
            let delta = (0..<states).map { Double(now[$0] &- before[$0]) }
            let total = delta.reduce(0, +)
            guard total > 0 else { return CPUUsage.Load() }
            return CPUUsage.Load(user: (delta[0] + delta[3]) / total, system: delta[1] / total)
        }
    }

    // MARK: - Memory

    private func sampleMemory() -> MemoryUsage {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var usage = MemoryUsage(total: ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS else { return usage }

        let pageSize = UInt64(sysconf(_SC_PAGESIZE))
        // Same breakdown as Activity Monitor: app memory + wired + compressed.
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)
        usage.used = (app + wired + compressed) * pageSize
        usage.app = app * pageSize
        usage.wired = wired * pageSize
        usage.compressed = compressed * pageSize
        usage.cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * pageSize

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            usage.swapUsed = swap.xsu_used
        }
        return usage
    }

    // MARK: - Processes

    /// Facts about a process that never change while it lives.
    private struct Identity {
        let startSeconds: UInt64
        let name: String
        let path: String
    }

    private func sampleProcesses(privileged: [pid_t: ProcessUsageRecord]?) -> [ProcessSample] {
        let processes = Self.listProcesses()
        guard !processes.isEmpty else { return [] }

        let now = mach_absolute_time()
        let elapsed = lastProcessSampleTime == 0 ? 0 : now &- lastProcessSampleTime
        // Mach time units to seconds.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
        let seconds = Double(elapsed) * secondsPerTick
        let networkRates = network.latest
        var usages: [pid_t: ProcessUsageRecord] = [:]
        var identities: [pid_t: Identity] = [:]
        var samples: [ProcessSample] = []
        usages.reserveCapacity(processes.count)
        samples.reserveCapacity(processes.count)

        for process in processes {
            let pid = process.kp_proc.p_pid
            guard pid > 0 else { continue }
            let uid = process.kp_eproc.e_ucred.cr_uid
            let started = process.kp_proc.p_un.__p_starttime
            let startSeconds = UInt64(max(started.tv_sec, 0))

            // A pid can be reused, so the cache entry must match the start time too.
            let identity: Identity
            if let cached = identityCache[pid], cached.startSeconds == startSeconds {
                identity = cached
            } else {
                var (name, path) = Self.nameAndPath(of: pid)
                if name.isEmpty {
                    // Short command name from the process table, the last resort.
                    name = withUnsafeBytes(of: process.kp_proc.p_comm) { bytes in
                        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                    }
                }
                if name.isEmpty { name = "pid \(pid)" }
                identity = Identity(startSeconds: startSeconds, name: name, path: path)
            }
            identities[pid] = identity

            // Reading usage directly fails for other users' processes; for
            // those, fall back to what the root helper reported, if anything.
            let usage = ProcessUsageRecord.read(pid: pid) ?? privileged?[pid]

            var cpu = 0.0
            var diskRead = 0.0
            var diskWrite = 0.0
            var power = 0.0
            if let usage {
                usages[pid] = usage
                // The counters only grow; a smaller value means the pid was reused.
                if elapsed > 0, let previous = lastUsage[pid], usage.cpuTime >= previous.cpuTime {
                    // Process times and mach_absolute_time share the same
                    // unit, so the ratio needs no timebase conversion.
                    cpu = Double(usage.cpuTime - previous.cpuTime) / Double(elapsed) * 100
                    if usage.diskRead >= previous.diskRead {
                        diskRead = Double(usage.diskRead - previous.diskRead) / seconds
                    }
                    if usage.diskWritten >= previous.diskWritten {
                        diskWrite = Double(usage.diskWritten - previous.diskWritten) / seconds
                    }
                    if usage.energy >= previous.energy {
                        power = Double(usage.energy - previous.energy) / 1e9 / seconds
                    }
                }
            }
            let networkRate = networkRates[pid]

            var sample =
                ProcessSample(
                    pid: pid,
                    parentPID: process.kp_eproc.e_ppid,
                    name: identity.name,
                    path: identity.path,
                    uid: uid,
                    user: userName(for: uid),
                    startDate: Date(
                        timeIntervalSince1970: Double(started.tv_sec)
                            + Double(started.tv_usec) / 1_000_000
                    ),
                    cpu: cpu,
                    memory: usage?.footprint ?? 0,
                    hasStats: usage != nil
                )
            sample.threads = Int(usage?.threads ?? 0)
            sample.cpuTime = Double(usage?.cpuTime ?? 0) * secondsPerTick
            sample.diskReadTotal = usage?.diskRead ?? 0
            sample.diskWrittenTotal = usage?.diskWritten ?? 0
            sample.diskRead = diskRead
            sample.diskWrite = diskWrite
            sample.power = power
            sample.networkIn = networkRate?.received ?? 0
            sample.networkOut = networkRate?.sent ?? 0
            samples.append(sample)
        }

        lastUsage = usages
        lastProcessSampleTime = now
        identityCache = identities
        return samples
    }

    private func userName(for uid: uid_t) -> String {
        if let cached = userNames[uid] { return cached }
        let name = getpwuid(uid).flatMap { $0.pointee.pw_name }.map { String(cString: $0) } ?? String(uid)
        userNames[uid] = name
        return name
    }

    private static func nameAndPath(of pid: pid_t) -> (name: String, path: String) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        if pathLength > 0 {
            let path = String(decoding: buffer.prefix(Int(pathLength)), as: UTF8.self)
            return ((path as NSString).lastPathComponent, path)
        }
        let nameLength = proc_name(pid, &buffer, UInt32(buffer.count))
        if nameLength > 0 {
            return (String(decoding: buffer.prefix(Int(nameLength)), as: UTF8.self), "")
        }
        return ("", "")
    }

    /// The whole process table in one call; unlike libproc this includes
    /// processes owned by other users.
    private static func listProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Headroom for processes that start between the two calls.
        let capacity = size / stride + 32
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * stride
        guard sysctl(&mib, 3, &processes, &size, nil, 0) == 0 else { return [] }
        processes.removeLast(capacity - min(size / stride, capacity))
        return processes
    }
}
