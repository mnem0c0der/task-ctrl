import Foundation
import IOKit.kext
import Observation

/// A kernel extension or a system extension known to this Mac.
struct Driver: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        case kernelExtension = "Kernel extension"
        /// Runs outside the kernel (DriverKit, network and endpoint extensions).
        case systemExtension = "System extension"
    }

    let bundleID: String
    let name: String
    let kind: Kind
    let version: String
    let vendor: String
    /// Folder of the bundle on disk; nil for pieces built into the kernel itself.
    let path: String?
    let isLoaded: Bool

    // Only known for loaded kernel extensions.
    var loadIndex: Int?
    var wiredSize: UInt64?
    var loadSize: UInt64?
    var dependencyCount: Int?
    /// How many other loaded extensions depend on this one.
    var referencedBy: Int?
    var uuid: String?
    /// Extra status text for system extensions, e.g. "activated enabled".
    var status: String?

    var id: String { bundleID + "|" + (path ?? "") }
    /// "__kernel__" is the kernel's own entry in the list of loaded extensions.
    var isApple: Bool { bundleID.hasPrefix("com.apple.") || bundleID == "__kernel__" }
    var wiredSortKey: UInt64 { wiredSize ?? 0 }
    /// Loaded extensions first when sorted ascending.
    var stateSortKey: Int { isLoaded ? 0 : 1 }
}

@MainActor
@Observable
final class DriversModel {
    private(set) var drivers: [Driver] = []
    private(set) var isLoading = false
    private(set) var updated: Date?

    func load() async {
        isLoading = true
        drivers = await Task.detached(priority: .userInitiated) { Self.read() }.value
        updated = Date()
        isLoading = false
    }

    // MARK: - Reading

    private nonisolated static func read() -> [Driver] {
        let loaded = (KextManagerCopyLoadedKextInfo(nil, nil)?.takeRetainedValue()
            as? [String: [String: Any]]) ?? [:]

        // Dependencies are listed as load indexes; count who points at whom.
        var references: [Int: Int] = [:]
        for info in loaded.values {
            for tag in info["OSBundleDependencies"] as? [NSNumber] ?? [] {
                references[tag.intValue, default: 0] += 1
            }
        }

        var drivers: [Driver] = []
        var seen = Set<String>()

        // Extensions installed on disk, enriched with the kernel's view when loaded.
        for installed in installedKernelExtensions() {
            guard seen.insert(installed.bundleID + "|" + installed.path).inserted else { continue }
            // The kernel reports a path per loaded extension; match on it so
            // that two copies of one extension are not both marked loaded.
            let info = loaded[installed.bundleID].flatMap { info -> [String: Any]? in
                let loadedPath = info["OSBundlePath"] as? String
                return loadedPath == nil || loadedPath == installed.path ? info : nil
            }
            drivers.append(driver(
                bundleID: installed.bundleID,
                name: installed.name,
                version: installed.version,
                path: installed.path,
                info: info,
                references: references
            ))
        }

        // Loaded pieces with no bundle of their own on disk (kernel interfaces).
        let listed = Set(drivers.filter(\.isLoaded).map(\.bundleID))
        for (bundleID, info) in loaded where !listed.contains(bundleID) {
            drivers.append(driver(
                bundleID: bundleID,
                name: bundleID == "__kernel__"
                    ? "macOS kernel"
                    : (bundleID.split(separator: ".").last.map(String.init) ?? bundleID),
                version: info["CFBundleVersion"] as? String ?? "",
                path: info["OSBundlePath"] as? String,
                info: info,
                references: references
            ))
        }

        drivers += systemExtensions()
        return drivers
    }

    private nonisolated static func driver(
        bundleID: String, name: String, version: String, path: String?,
        info: [String: Any]?, references: [Int: Int]
    ) -> Driver {
        var driver = Driver(
            bundleID: bundleID,
            name: name,
            kind: .kernelExtension,
            version: info?["CFBundleVersion"] as? String ?? version,
            vendor: vendor(of: bundleID),
            path: path,
            isLoaded: info != nil
        )
        if let info {
            let tag = (info["OSBundleLoadTag"] as? NSNumber)?.intValue
            driver.loadIndex = tag
            driver.wiredSize = (info["OSBundleWiredSize"] as? NSNumber)?.uint64Value
            driver.loadSize = (info["OSBundleLoadSize"] as? NSNumber)?.uint64Value
            driver.dependencyCount = (info["OSBundleDependencies"] as? [Any])?.count
            driver.referencedBy = tag.map { references[$0] ?? 0 }
            if let data = info["OSBundleUUID"] as? Data, data.count == 16 {
                driver.uuid = data.withUnsafeBytes { NSUUID(uuidBytes: $0.bindMemory(to: UInt8.self).baseAddress) }
                    .uuidString
            }
        }
        return driver
    }

    private struct InstalledExtension {
        let bundleID: String
        let name: String
        let version: String
        let path: String
    }

    /// Bundles in the two extension folders, including ones nested as plug-ins.
    private nonisolated static func installedKernelExtensions() -> [InstalledExtension] {
        var found: [InstalledExtension] = []

        func visit(_ folder: String, depth: Int) {
            guard depth < 4 else { return }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where name.hasSuffix(".kext") {
                let path = folder + "/" + name
                // macOS bundles keep Info.plist in Contents, a few old ones at the top.
                let plist = (NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
                    ?? NSDictionary(contentsOfFile: path + "/Info.plist")) as? [String: Any]
                if let bundleID = plist?["CFBundleIdentifier"] as? String {
                    found.append(InstalledExtension(
                        bundleID: bundleID,
                        name: plist?["CFBundleName"] as? String ?? String(name.dropLast(5)),
                        version: plist?["CFBundleShortVersionString"] as? String
                            ?? plist?["CFBundleVersion"] as? String ?? "",
                        path: path
                    ))
                }
                visit(path + "/Contents/PlugIns", depth: depth + 1)
            }
        }
        visit("/System/Library/Extensions", depth: 0)
        visit("/Library/Extensions", depth: 0)
        return found
    }

    /// Parses `systemextensionsctl list`, whose rows are tab-separated:
    /// enabled, active, team, "bundle.id (version)", name, "[state]".
    private nonisolated static func systemExtensions() -> [Driver] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/systemextensionsctl")
        process.arguments = ["list"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var drivers: [Driver] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, fields[2] != "teamID",
                  let open = fields[3].lastIndex(of: "("), fields[3].hasSuffix(")")
            else { continue }
            let bundleID = fields[3][..<open].trimmingCharacters(in: .whitespaces)
            let version = String(fields[3][fields[3].index(after: open)...].dropLast())
            var driver = Driver(
                bundleID: bundleID,
                name: fields[4].isEmpty ? bundleID : fields[4],
                kind: .systemExtension,
                version: version,
                vendor: bundleID.hasPrefix("com.apple.") ? "Apple" : "\(vendor(of: bundleID)) (team \(fields[2]))",
                path: nil,
                isLoaded: fields[1] == "*"
            )
            driver.status = fields[5].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            drivers.append(driver)
        }
        return drivers
    }

    /// "com.fortinet.driver.x" → "Fortinet". A guess from the identifier, not
    /// a verified signer.
    private nonisolated static func vendor(of bundleID: String) -> String {
        if bundleID == "__kernel__" { return "Apple" }
        let parts = bundleID.split(separator: ".")
        guard parts.count >= 2 else { return "Unknown" }
        if parts[1] == "apple" { return "Apple" }
        return parts[1].prefix(1).uppercased() + parts[1].dropFirst()
    }
}
