import Foundation

/// One of the chip's media blocks and how much of the time it was working.
struct MediaEngineReading: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, CaseIterable {
        case videoEncode, videoDecode, scaler, jpeg, proRes

        /// How the power manager's channels for this kind of block start.
        var channelPrefix: String {
            switch self {
            case .videoEncode: "AVE"
            case .videoDecode: "AVD"
            case .scaler: "MSR"
            case .jpeg: "JPEG"
            case .proRes: "SCODEC"
            }
        }

        var title: String {
            switch self {
            case .videoEncode: "Video encode"
            case .videoDecode: "Video decode"
            case .scaler: "Media scaler"
            case .jpeg: "JPEG codec"
            case .proRes: "ProRes"
            }
        }
    }

    let kind: Kind
    /// "Video encode 0", "Video decode", "Media scaler 1".
    let name: String
    /// Share of the interval the block spent above its idle voltage floor,
    /// 0...1. It says the block was in use, not how much of it.
    let active: Double

    var id: String { name }
}

/// Reads how long each of the chip's media blocks was kept above its idle
/// voltage, from the power manager's counters.
final class MediaEngineReader {
    private let subscription: CFTypeRef
    private let channels: CFMutableDictionary
    private var previous: CFDictionary?
    /// The channels the chip lists, sorted, for each kind of block.
    private let blocks: [(kind: MediaEngineReading.Kind, channels: [String])]

    /// Nil when the chip reports no media blocks.
    init?() {
        guard let floors = IOReportCopyChannelsInGroup("PMP0" as CFString, "SOC Floor" as CFString, 0, 0, 0),
              let desired = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, floors)
        else { return nil }

        let kinds = MediaEngineReading.Kind.allCases
        let wanted = ((floors as NSDictionary)["IOReportChannels"] as? [NSDictionary] ?? []).filter {
            guard let name = IOReportChannelGetChannelName($0) as String? else { return false }
            return kinds.contains { name.hasPrefix($0.channelPrefix) }
        }
        guard !wanted.isEmpty else { return nil }
        let names = wanted.compactMap { IOReportChannelGetChannelName($0) as String? }
        blocks = kinds.map { kind in
            (kind, names.filter { $0.hasPrefix(kind.channelPrefix) }.sorted())
        }
        (desired as NSMutableDictionary)["IOReportChannels"] = wanted

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = IOReportCreateSubscription(nil, desired, &subscribed, 0, nil),
              let channels = subscribed?.takeRetainedValue()
        else { return nil }
        self.subscription = subscription
        self.channels = channels
    }

    /// Every block the chip lists, grouped by kind. Empty for the first
    /// read, which has nothing to compare with.
    func read() -> [MediaEngineReading] {
        guard let sample = IOReportCreateSamples(subscription, channels, nil) else { return [] }
        defer { previous = sample }
        guard let previous, let delta = IOReportCreateSamplesDelta(previous, sample, nil) else { return [] }

        var active: [String: Double] = [:]
        for channel in (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] ?? [] {
            guard let name = IOReportChannelGetChannelName(channel) as String? else { continue }
            // State 0 is the idle floor; the others are raised voltages.
            var total = 0.0
            var idle = 0.0
            for index in 0..<IOReportStateGetCount(channel) {
                let time = Double(IOReportStateGetResidency(channel, index))
                total += time
                if index == 0 { idle = time }
            }
            if total > 0 { active[name] = 1 - idle / total }
        }

        return blocks.flatMap { kind, channels in
            channels.enumerated().map { index, channel in
                MediaEngineReading(
                    kind: kind,
                    name: channels.count > 1 ? "\(kind.title) \(index)" : kind.title,
                    // A block that is switched off reports no time at all.
                    active: active[channel] ?? 0
                )
            }
        }
    }
}
