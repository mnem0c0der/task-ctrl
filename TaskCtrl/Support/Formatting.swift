import Foundation

extension UInt64 {
    /// "18.5 GB" style, binary units as used for RAM.
    var memoryFormatted: String {
        Int64(clamping: self).formatted(.byteCount(style: .memory, spellsOutZero: false))
    }

    /// "245 GB" style, decimal units as used for storage.
    var storageFormatted: String {
        Int64(clamping: self).formatted(.byteCount(style: .file, spellsOutZero: false))
    }
}

extension Double {
    /// "46.8 °C"
    var temperatureFormatted: String {
        formatted(.number.precision(.fractionLength(1))) + " °C"
    }

    /// "7.2 W"
    var powerFormatted: String {
        formatted(.number.precision(.fractionLength(1))) + " W"
    }

    /// Per-process power: "66 mW" below one watt, "1.2 W" above.
    var smallPowerFormatted: String {
        self < 1 ? "\(Int((self * 1000).rounded())) mW" : powerFormatted
    }

    /// Processor time as "1:23:45" or "4:05.3".
    var cpuTimeFormatted: String {
        let total = Int(self)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%04.1f", total / 60, self - Double(total / 60 * 60))
    }

    /// Bytes per second as "5.9 kB/s".
    var rateFormatted: String {
        Int64(max(self, 0)).formatted(.byteCount(style: .file, spellsOutZero: false)) + "/s"
    }

    /// Formats a 0...1 fraction as "9.1%".
    var percentFormatted: String {
        formatted(.percent.precision(.fractionLength(1)))
    }
}
