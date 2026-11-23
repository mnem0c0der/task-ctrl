import Foundation

/// Turns the kernel's cumulative energy counters into watts between two reads.
final class EnergyReader {
    private let subscription: CFTypeRef
    private let channels: CFMutableDictionary
    private var previous: (sample: CFDictionary, time: ContinuousClock.Instant)?

    init?() {
        guard let all = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0),
              let desired = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, all)
        else { return nil }

        // The group has hundreds of per-core channels; keep only the totals.
        let wanted = ((all as NSDictionary)["IOReportChannels"] as? [NSDictionary] ?? []).filter {
            let name = IOReportChannelGetChannelName($0) as String?
            return name == "CPU Energy" || name == "GPU Energy"
        }
        guard !wanted.isEmpty else { return nil }
        (desired as NSMutableDictionary)["IOReportChannels"] = wanted

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = IOReportCreateSubscription(nil, desired, &subscribed, 0, nil),
              let channels = subscribed?.takeRetainedValue()
        else { return nil }
        self.subscription = subscription
        self.channels = channels
    }

    func read() -> (cpu: Double?, gpu: Double?)? {
        guard let sample = IOReportCreateSamples(subscription, channels, nil) else { return nil }
        let now = ContinuousClock.now
        defer { previous = (sample, now) }
        guard let previous,
              let delta = IOReportCreateSamplesDelta(previous.sample, sample, nil)
        else { return nil }

        let elapsed = now - previous.time
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        guard seconds > 0 else { return nil }

        var cpu: Double?
        var gpu: Double?
        for channel in (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] ?? [] {
            let unit = (IOReportChannelGetUnitLabel(channel) as String? ?? "")
                .trimmingCharacters(in: .whitespaces)
            let joulesPerUnit: Double
            switch unit {
            case "mJ": joulesPerUnit = 1e-3
            case "uJ": joulesPerUnit = 1e-6
            case "nJ": joulesPerUnit = 1e-9
            default: continue
            }
            let watts = Double(IOReportSimpleGetIntegerValue(channel, 0)) * joulesPerUnit / seconds
            switch IOReportChannelGetChannelName(channel) as String? {
            // Some macOS versions report a constant zero here, for root as
            // well as for us (tried through the helper); a running CPU never
            // draws nothing, so treat zero as "no reading".
            case "CPU Energy": cpu = watts > 0 ? watts : nil
            case "GPU Energy": gpu = watts
            default: break
            }
        }
        return (cpu, gpu)
    }
}
