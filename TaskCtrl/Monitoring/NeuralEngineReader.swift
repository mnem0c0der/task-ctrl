import Foundation

struct NeuralEngineReadings: Sendable, Equatable {
    /// How many Neural Engine blocks the chip reports.
    var blocks = 0
    /// Share of the interval the blocks were powered on, averaged over the
    /// blocks, 0...1. The system keeps a block on for a few seconds after its
    /// last job, so this says how much of the time it was in use, not how
    /// hard it worked.
    var active: Double = 0
    /// Watts; nil when the system reports no energy for it.
    var power: Double?
    /// Joules used over the interval; nil along with `power`.
    var energy: Double?
}

/// Reads how long the Neural Engine was powered on between two reads, from
/// the kernel's power state counters.
final class NeuralEngineReader {
    private let subscription: CFTypeRef
    private let channels: CFMutableDictionary
    private var previous: (sample: CFDictionary, time: ContinuousClock.Instant)?

    private static let prefix = "ANE"
    /// The one state in which a block is switched off.
    private static let inactiveState = "INACT"

    /// Nil when the chip reports no Neural Engine.
    init?() {
        guard let states = IOReportCopyChannelsInGroup(
            "SoC Stats" as CFString, "Cluster Power States" as CFString, 0, 0, 0
        ), let desired = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, states)
        else { return nil }

        func ours(_ group: CFDictionary?) -> [NSDictionary] {
            ((group as NSDictionary?)?["IOReportChannels"] as? [NSDictionary] ?? []).filter {
                (IOReportChannelGetChannelName($0) as String?)?.hasPrefix(Self.prefix) == true
            }
        }
        let wanted = ours(states)
        guard !wanted.isEmpty else { return nil }
        let energy = ours(IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0))
        (desired as NSMutableDictionary)["IOReportChannels"] = wanted + energy

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = IOReportCreateSubscription(nil, desired, &subscribed, 0, nil),
              let channels = subscribed?.takeRetainedValue()
        else { return nil }
        self.subscription = subscription
        self.channels = channels
    }

    /// Nil for the first read, which has nothing to compare with.
    func read() -> NeuralEngineReadings? {
        guard let sample = IOReportCreateSamples(subscription, channels, nil) else { return nil }
        let now = ContinuousClock.now
        defer { previous = (sample, now) }
        guard let previous,
              let delta = IOReportCreateSamplesDelta(previous.sample, sample, nil)
        else { return nil }

        let elapsed = now - previous.time
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        var readings = NeuralEngineReadings()
        var joules = 0.0
        for channel in (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] ?? [] {
            let unit = (IOReportChannelGetUnitLabel(channel) as String? ?? "")
                .trimmingCharacters(in: .whitespaces)
            switch unit {
            case "mJ": joules += Double(IOReportSimpleGetIntegerValue(channel, 0)) * 1e-3
            case "uJ": joules += Double(IOReportSimpleGetIntegerValue(channel, 0)) * 1e-6
            case "nJ": joules += Double(IOReportSimpleGetIntegerValue(channel, 0)) * 1e-9
            default:
                // A power state channel: time spent in each state.
                var total = 0.0
                var inactive = 0.0
                for index in 0..<IOReportStateGetCount(channel) {
                    let time = Double(IOReportStateGetResidency(channel, index))
                    total += time
                    if IOReportStateGetNameForIndex(channel, index) as String? == Self.inactiveState {
                        inactive += time
                    }
                }
                guard total > 0 else { continue }
                readings.blocks += 1
                readings.active += 1 - inactive / total
            }
        }
        // Some macOS versions report a constant zero for energy, even while
        // the block is running; treat zero as "no reading".
        if seconds > 0, joules > 0 {
            readings.power = joules / seconds
            readings.energy = joules
        }
        if readings.blocks > 1 { readings.active /= Double(readings.blocks) }
        return readings
    }
}
