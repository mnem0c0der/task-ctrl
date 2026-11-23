import Foundation

/// CPU load as fractions of total capacity (0...1) across all cores.
struct CPUUsage: Sendable, Equatable {
    /// Load of one core or the average of a group of cores, as 0...1 fractions.
    struct Load: Sendable, Equatable {
        var user: Double = 0
        var system: Double = 0

        var total: Double { user + system }
    }

    var user: Double = 0
    var system: Double = 0
    /// One entry per logical CPU, in the kernel's numbering.
    var cores: [Load] = []
    /// Averages over the performance and the efficiency cores.
    var performance = Load()
    var efficiency = Load()

    var total: Double { user + system }
}

struct MemoryUsage: Sendable, Equatable {
    var used: UInt64 = 0
    var total: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    /// The three parts `used` is made of.
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0

    var fraction: Double {
        total == 0 ? 0 : Double(used) / Double(total)
    }
}

struct ProcessSample: Sendable, Identifiable, Equatable {
    let pid: pid_t
    let parentPID: pid_t
    let name: String
    /// Full path of the executable; empty when the system does not disclose it.
    let path: String
    let uid: uid_t
    let user: String
    let startDate: Date
    /// Percent of a single core, so a busy multi-threaded process can exceed 100.
    var cpu: Double
    /// Physical footprint in bytes, the same figure Activity Monitor shows.
    var memory: UInt64
    /// False for processes of other users: without root the system hides
    /// their CPU and memory figures, so `cpu` and `memory` are zero.
    var hasStats: Bool

    /// The app the system holds responsible for this process, for helpers
    /// that launchd starts on an app's behalf. Zero when the process
    /// answers for itself or the system does not say.
    var responsiblePID: pid_t = 0
    /// Zero when unknown.
    var threads = 0
    /// Processor time used since the process started, seconds.
    var cpuTime: TimeInterval = 0
    /// Bytes read from and written to disk since the process started.
    var diskReadTotal: UInt64 = 0
    var diskWrittenTotal: UInt64 = 0
    /// Bytes per second.
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var networkIn: Double = 0
    var networkOut: Double = 0
    /// Power the kernel attributes to the process, watts.
    var power: Double = 0

    // The rest is filled in for the process table only.

    /// `cpu` averaged over the last several seconds. Steadier than `cpu`,
    /// so a list sorted by it does not reshuffle on every sample.
    var smoothedCPU: Double = 0
    /// How recently the CPU and memory figures on screen changed: 1 on the
    /// refresh they changed, fading to 0 over the next few.
    var cpuHeat: Double = 0
    var memoryHeat: Double = 0
    /// True for a process that has just quit and is still listed for a moment.
    var hasExited = false

    /// Adds another process's live figures to this one, for a group total.
    mutating func add(_ other: ProcessSample) {
        cpu += other.cpu
        smoothedCPU += other.smoothedCPU
        cpuHeat = max(cpuHeat, other.cpuHeat)
        memoryHeat = max(memoryHeat, other.memoryHeat)
        memory += other.memory
        threads += other.threads
        diskRead += other.diskRead
        diskWrite += other.diskWrite
        networkIn += other.networkIn
        networkOut += other.networkOut
        power += other.power
        hasStats = hasStats || other.hasStats
    }

    var disk: Double { diskRead + diskWrite }
    var network: Double { networkIn + networkOut }

    var id: pid_t { pid }
}

struct SystemSnapshot: Sendable {
    var date = Date()
    var cpu = CPUUsage()
    var memory = MemoryUsage()
    var processes: [ProcessSample] = []
    var sensors = SensorReadings()
    var activity = ActivityReadings()
    var processCount: Int { processes.count }
    /// Sum of what the kernel attributes to individual processes, watts.
    var processPower: Double { processes.reduce(0) { $0 + $1.power } }
}

struct HistoryPoint: Identifiable, Sendable {
    let date: Date
    let cpu: Double
    /// Kernel share of `cpu`, 0...1.
    var kernel: Double = 0
    let memory: Double
    /// Sensor values; nil while a sensor has no reading.
    var gpu: Double?
    var gpuRenderer: Double?
    var gpuTiler: Double?
    /// Bytes.
    var gpuMemory: Double?
    /// Active share of each media block, by the block's name.
    var mediaEngines: [String: Double] = [:]
    /// Share of the time the Neural Engine was powered on, 0...1.
    var neuralEngine: Double?
    var temperature: Double?
    var power: Double?
    var performanceCores = CPUUsage.Load()
    var efficiencyCores = CPUUsage.Load()
    /// Load of every logical CPU, in the kernel's numbering.
    var cores: [CPUUsage.Load] = []
    /// Bytes per second.
    var networkIn: Double = 0
    var networkOut: Double = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    /// The busiest processes at that moment, busiest first. Enough of them
    /// that an average over several samples is still meaningful.
    var topProcesses: [ProcessSample] = []

    /// How many processes each point remembers.
    static let topProcessCount = 40

    var id: Date { date }
}

extension Array where Element == ProcessSample {
    /// The `count` busiest, busiest first. Ties go to the lower PID, so
    /// equal rows don't trade places from one sample to the next.
    func busiest(_ count: Int) -> [ProcessSample] {
        Array(sorted { ($0.cpu, $1.pid) > ($1.cpu, $0.pid) }.prefix(count))
    }
}
