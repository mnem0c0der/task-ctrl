import Foundation

/// How hard the machine is being pushed: three signals on a common 0...1
/// scale. The worst of them is the overall figure.
struct SystemPressure: Sendable, Equatable {
    enum Level: Sendable, Comparable {
        case low, elevated, high, critical

        /// Scores at which each level starts.
        static let elevatedScore = 0.5
        static let highScore = 0.75
        static let criticalScore = 0.9

        init(score: Double) {
            self = switch score {
            case Self.criticalScore...: .critical
            case Self.highScore...: .high
            case Self.elevatedScore...: .elevated
            default: .low
            }
        }

        var label: String {
            switch self {
            case .low: "Low"
            case .elevated: "Elevated"
            case .high: "High"
            case .critical: "Critical"
            }
        }
    }

    enum Signal: Sendable, CaseIterable {
        case cpuQueue, memory, storage

        var title: String {
            switch self {
            case .cpuQueue: "CPU queue"
            case .memory: "Memory pressure"
            case .storage: "Storage activity"
            }
        }
    }

    /// Load average per logical processor that fills the CPU queue scale:
    /// two and a half threads wanting every processor.
    static let fullQueuePerProcessor = 2.5
    /// Shares of installed memory in use at which the memory score turns
    /// elevated, high and critical.
    static let memoryThresholds = (elevated: 0.8, high: 0.9, critical: 0.97)

    let cpuQueue: Double
    let memory: Double
    let storage: Double

    init(
        activity: ActivityReadings,
        memory: MemoryUsage,
        processors: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        let perProcessor = activity.loadAverage / Double(max(processors, 1))
        cpuQueue = min(max(perProcessor / Self.fullQueuePerProcessor, 0), 1)

        // The kernel's own verdict is a floor: it knows about pressure that
        // the share of memory in use does not show.
        let floor = switch activity.memoryPressure {
        case .normal: 0.0
        case .warning: Level.elevatedScore
        case .critical: Level.criticalScore
        }
        self.memory = max(Self.memoryScore(inUse: memory.fraction), floor)

        storage = min(max(activity.storage.busy, 0), 1)
    }

    /// Maps the share of memory in use onto the score scale, so that the
    /// thresholds land exactly where the levels start.
    static func memoryScore(inUse fraction: Double) -> Double {
        let points: [(x: Double, y: Double)] = [
            (0, 0),
            (memoryThresholds.elevated, Level.elevatedScore),
            (memoryThresholds.high, Level.highScore),
            (memoryThresholds.critical, Level.criticalScore),
            (1, 1),
        ]
        let x = min(max(fraction, 0), 1)
        for (from, to) in zip(points, points.dropFirst()) where x <= to.x {
            return from.y + (x - from.x) / (to.x - from.x) * (to.y - from.y)
        }
        return 1
    }

    func score(of signal: Signal) -> Double {
        switch signal {
        case .cpuQueue: cpuQueue
        case .memory: memory
        case .storage: storage
        }
    }

    /// The signal with the highest score; it sets the overall figure.
    var primary: Signal {
        Signal.allCases.max { score(of: $0) < score(of: $1) } ?? .cpuQueue
    }

    var score: Double { score(of: primary) }
    var level: Level { Level(score: score) }
}
