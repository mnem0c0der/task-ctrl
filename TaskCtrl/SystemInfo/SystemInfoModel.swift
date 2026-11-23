import Foundation
import Observation

/// A section of the system report, backed by one `system_profiler` data type.
enum SystemInfoCategory: String, CaseIterable, Identifiable {
    case hardware, memory, storage, audio, bluetooth, camera, cardReader, displays, controller
    case nvme, spi, secureElement, smartCards, thunderbolt, usb, power
    case wifi, network, locations, networkVolumes, firewall
    case software

    enum Group: String, CaseIterable {
        case hardware = "Hardware"
        case network = "Network"
        case software = "Software"
    }

    var id: Self { self }

    var group: Group {
        switch self {
        case .wifi, .network, .locations, .networkVolumes, .firewall: .network
        case .software: .software
        default: .hardware
        }
    }

    var title: String {
        switch self {
        case .hardware: "Hardware Overview"
        case .memory: "Memory"
        case .storage: "Storage"
        case .audio: "Audio"
        case .bluetooth: "Bluetooth"
        case .camera: "Camera"
        case .cardReader: "Card Reader"
        case .displays: "Graphics/Displays"
        case .controller: "Controller"
        case .nvme: "NVMExpress"
        case .spi: "SPI"
        case .secureElement: "Secure Element"
        case .smartCards: "Smart Cards"
        case .thunderbolt: "Thunderbolt/USB4"
        case .usb: "USB"
        case .power: "Power"
        case .wifi: "Wi-Fi"
        case .network: "Network"
        case .locations: "Locations"
        case .networkVolumes: "Network Volumes"
        case .firewall: "Firewall"
        case .software: "System Software"
        }
    }

    var symbol: String {
        switch self {
        case .hardware: "desktopcomputer"
        case .memory: "memorychip"
        case .storage: "externaldrive"
        case .audio: "speaker.wave.2"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        case .camera: "camera"
        case .cardReader: "sdcard"
        case .displays: "display"
        case .controller, .spi: "cpu"
        case .nvme: "internaldrive"
        case .secureElement: "lock.shield"
        case .smartCards: "creditcard"
        case .thunderbolt: "bolt"
        case .usb: "cable.connector"
        case .power: "bolt.circle"
        case .wifi: "wifi"
        case .network: "network"
        case .locations: "mappin.and.ellipse"
        case .networkVolumes: "externaldrive.connected.to.line.below"
        case .firewall: "shield"
        case .software: "macwindow"
        }
    }

    /// Name `system_profiler` knows the section by.
    var dataType: String {
        switch self {
        case .hardware: "SPHardwareDataType"
        case .memory: "SPMemoryDataType"
        case .storage: "SPStorageDataType"
        case .audio: "SPAudioDataType"
        case .bluetooth: "SPBluetoothDataType"
        case .camera: "SPCameraDataType"
        case .cardReader: "SPCardReaderDataType"
        case .displays: "SPDisplaysDataType"
        case .controller: "SPiBridgeDataType"
        case .nvme: "SPNVMeDataType"
        case .spi: "SPSPIDataType"
        case .secureElement: "SPSecureElementDataType"
        case .smartCards: "SPSmartCardsDataType"
        case .thunderbolt: "SPThunderboltDataType"
        case .usb: "SPUSBHostDataType"
        case .power: "SPPowerDataType"
        case .wifi: "SPAirPortDataType"
        case .network: "SPNetworkDataType"
        case .locations: "SPNetworkLocationDataType"
        case .networkVolumes: "SPNetworkVolumeDataType"
        case .firewall: "SPFirewallDataType"
        case .software: "SPSoftwareDataType"
        }
    }
}

/// One line of a report: a section heading (no value) or a name with its value.
struct SystemInfoRow: Identifiable, Sendable {
    let id: Int
    /// Nesting level, 0 for the top of the section.
    let depth: Int
    let title: String
    let value: String?

    var isHeading: Bool { value == nil }
}

/// Loads report sections on demand by running the system's own
/// `system_profiler`, the tool behind the System Information app.
@MainActor
@Observable
final class SystemInfoModel {
    enum State {
        case loading
        case loaded(rows: [SystemInfoRow], text: String)
        case failed(String)
    }

    enum Format {
        case text, json

        var fileExtension: String {
            switch self {
            case .text: "txt"
            case .json: "json"
            }
        }
    }

    private(set) var sections: [SystemInfoCategory: State] = [:]

    /// Loads the section unless it is already there; `force` reloads it.
    func load(_ category: SystemInfoCategory, force: Bool = false) {
        if !force, sections[category] != nil { return }
        sections[category] = .loading
        Task {
            do {
                let text = try await Self.run(arguments: [category.dataType])
                sections[category] = .loaded(rows: Self.parse(text), text: text)
            } catch {
                sections[category] = .failed(error.localizedDescription)
            }
        }
    }

    /// Sections that have been read so far, in sidebar order.
    var loadedCategories: [SystemInfoCategory] {
        SystemInfoCategory.allCases.filter {
            if case .loaded = sections[$0] { true } else { false }
        }
    }

    /// The reports of the given sections as one file body.
    func export(_ categories: [SystemInfoCategory], as format: Format) async throws -> String {
        switch format {
        case .text:
            var parts: [String] = []
            for category in categories {
                if case .loaded(_, let text) = sections[category] {
                    parts.append(text)
                } else {
                    parts.append(try await Self.run(arguments: [category.dataType]))
                }
            }
            return parts.joined(separator: "\n")
        case .json:
            // One call yields a single JSON object with a key per section.
            return try await Self.run(arguments: ["-json"] + categories.map(\.dataType))
        }
    }

    // MARK: - Running system_profiler

    private static func run(arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/sbin/system_profiler")
            // Some sections query slow hardware; do not wait forever.
            process.arguments = ["-timeout", "30"] + arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            // Read before waiting: a full pipe would otherwise block the tool.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    // MARK: - Parsing

    /// Turns the tool's indented text into rows. The report looks like
    ///
    ///     Hardware:
    ///
    ///         Hardware Overview:
    ///
    ///           Model Name: MacBook Pro
    ///
    /// where a line ending in a colon is a heading and deeper indentation
    /// means nesting. The first, unindented line only repeats the section
    /// name and is dropped.
    static func parse(_ text: String) -> [SystemInfoRow] {
        var rows: [SystemInfoRow] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let indent = line.prefix { $0 == " " }.count
            let content = line.dropFirst(indent).trimmingCharacters(in: .whitespaces)
            guard indent > 0, !content.isEmpty else { continue }
            // Headings sit at 4, 8, 12… spaces and their values 2 deeper.
            let depth = max(0, (indent - 4) / 2)

            if let separator = content.range(of: ": ") {
                rows.append(SystemInfoRow(
                    id: rows.count,
                    depth: depth,
                    title: String(content[..<separator.lowerBound]),
                    value: String(content[separator.upperBound...])
                ))
            } else if content.hasSuffix(":") {
                rows.append(SystemInfoRow(
                    id: rows.count, depth: depth, title: String(content.dropLast()), value: nil
                ))
            } else {
                // A bare line continues a list started by the heading above.
                rows.append(SystemInfoRow(id: rows.count, depth: depth, title: "", value: content))
            }
        }
        return rows
    }
}
