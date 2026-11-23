import AppKit
import Foundation
import Observation
import Security

struct InstalledApp: Identifiable, Sendable, Equatable {
    let url: URL
    let name: String
    let version: String?
    let bundleID: String?
    /// Part of macOS itself; cannot be removed.
    let isSystem: Bool
    let modified: Date?
    let lastOpened: Date?
    /// Size of the app bundle on disk; nil until measured.
    var size: UInt64?

    var id: String { url.path(percentEncoded: false) }
    /// Sorts apps whose size is not known yet as the smallest.
    var sizeSortKey: UInt64 { size ?? 0 }
}

/// A file or folder an app left outside its own bundle.
struct RelatedFile: Identifiable, Sendable, Equatable {
    let url: URL
    /// Nil when the size cannot be measured without asking for extra access.
    let size: UInt64?

    var id: String { url.path(percentEncoded: false) }
}

@MainActor
@Observable
final class InstalledAppsModel {
    private(set) var apps: [InstalledApp] = []
    private(set) var isLoading = false
    /// Leftovers by app id; an entry appears once the search for that app is done.
    private(set) var relatedFiles: [InstalledApp.ID: [RelatedFile]] = [:]
    /// Who signed each app, by app id.
    private(set) var publishers: [InstalledApp.ID: String] = [:]

    private var sizeTask: Task<Void, Never>?

    func load() async {
        isLoading = true
        sizeTask?.cancel()
        apps = await Task.detached(priority: .userInitiated) { Self.findApps() }.value
        isLoading = false

        // Measuring bundles means walking every file, so it trickles in afterwards.
        let targets = apps.map(\.url)
        sizeTask = Task {
            for url in targets {
                if Task.isCancelled { return }
                let size = await Task.detached(priority: .utility) { Self.size(of: url) }.value
                if let index = apps.firstIndex(where: { $0.url == url }) {
                    apps[index].size = size
                }
            }
        }
    }

    /// Looks up the publisher and the leftovers of an app, once.
    func loadDetails(for app: InstalledApp) {
        if publishers[app.id] == nil {
            Task {
                let name = await Task.detached { Self.publisher(of: app.url) }.value
                publishers[app.id] = name ?? "Unknown"
            }
        }
        if relatedFiles[app.id] == nil {
            Task {
                relatedFiles[app.id] = await Task.detached(priority: .userInitiated) {
                    Self.findRelatedFiles(for: app)
                }.value
            }
        }
    }

    /// Why an app cannot be uninstalled right now, or nil when it can.
    func blocker(for app: InstalledApp) -> String? {
        if app.isSystem { return "\(app.name) is part of macOS and cannot be removed." }
        if app.url.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
            return "TaskCtrl cannot uninstall itself."
        }
        if let bundleID = app.bundleID,
           !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            return "\(app.name) is running. Quit it first."
        }
        return nil
    }

    /// Moves the apps and their leftovers to the Trash. Nothing is deleted
    /// outright, so everything can be put back from the Trash.
    func uninstall(_ targets: [InstalledApp]) async throws {
        var urls: [URL] = []
        for app in targets {
            urls.append(app.url)
            let leftovers: [RelatedFile]
            if let known = relatedFiles[app.id] {
                leftovers = known
            } else {
                leftovers = await Task.detached { Self.findRelatedFiles(for: app) }.value
            }
            urls += leftovers.map(\.url)
        }
        // Finder does the move, so it can ask for an administrator password
        // when an app belongs to the system-wide Applications folder.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle(urls) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        await load()
    }

    // MARK: - Finding apps

    private nonisolated static func findApps() -> [InstalledApp] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders: [(url: URL, isSystem: Bool)] = [
            (URL(filePath: "/Applications"), false),
            (URL(filePath: "/Applications/Utilities"), false),
            (home.appending(path: "Applications"), false),
            (URL(filePath: "/System/Applications"), true),
            (URL(filePath: "/System/Applications/Utilities"), true),
        ]
        let keys: [URLResourceKey] = [.contentModificationDateKey]

        var apps: [InstalledApp] = []
        for folder in folders {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folder.url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )) ?? []
            for url in contents where url.pathExtension == "app" {
                let info = Bundle(url: url)?.infoDictionary
                // The name Finder shows, which may be localized.
                var name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
                if name.hasSuffix(".app") { name.removeLast(4) }
                if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                apps.append(InstalledApp(
                    url: url,
                    name: name,
                    version: info?["CFBundleShortVersionString"] as? String,
                    bundleID: info?["CFBundleIdentifier"] as? String,
                    isSystem: folder.isSystem,
                    modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate,
                    lastOpened: NSMetadataItem(url: url)?
                        .value(forAttribute: kMDItemLastUsedDate as String) as? Date
                ))
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func size(of url: URL) -> UInt64? {
        // Only the total matters here, so keep no per-file nodes.
        (try? DiskScanner.scan(url, minimumFileSize: .max))?.root.size
    }

    private nonisolated static func publisher(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return nil
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let details = info as? [String: Any],
              let certificates = details[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first
        else { return nil }
        return SecCertificateCopySubjectSummary(leaf) as String?
    }

    // MARK: - Finding leftovers

    /// Looks in the usual per-user Library spots for items named exactly after
    /// the app's bundle identifier (or, for two folders that use it, the
    /// app's name). Exact names only: a looser match could sweep up another
    /// app's data.
    private nonisolated static func findRelatedFiles(for app: InstalledApp) -> [RelatedFile] {
        // A proper identifier has dots, e.g. "com.acme.editor". Anything
        // shorter is too generic to match on safely.
        guard let bundleID = app.bundleID, bundleID.split(separator: ".").count >= 2 else { return [] }
        let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
        let manager = FileManager.default

        var candidates: [URL] = [
            library.appending(path: "Application Support/\(bundleID)"),
            library.appending(path: "Caches/\(bundleID)"),
            library.appending(path: "Preferences/\(bundleID).plist"),
            library.appending(path: "Saved Application State/\(bundleID).savedState"),
            library.appending(path: "HTTPStorages/\(bundleID)"),
            library.appending(path: "HTTPStorages/\(bundleID).binarycookies"),
            library.appending(path: "WebKit/\(bundleID)"),
            library.appending(path: "Cookies/\(bundleID).binarycookies"),
            library.appending(path: "Logs/\(bundleID)"),
            library.appending(path: "Application Scripts/\(bundleID)"),
        ]
        if app.name.count >= 3 {
            candidates.append(library.appending(path: "Application Support/\(app.name)"))
            candidates.append(library.appending(path: "Logs/\(app.name)"))
        }
        // Launch agents and per-host preferences carry the identifier as a prefix.
        for (folder, suffix) in [("LaunchAgents", ".plist"), ("Preferences/ByHost", ".plist")] {
            let directory = library.appending(path: folder)
            let names = (try? manager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
            for name in names where name.hasSuffix(suffix)
                && (name == bundleID + suffix || name.hasPrefix(bundleID + ".")) {
                candidates.append(directory.appending(path: name))
            }
        }

        var files: [RelatedFile] = candidates
            .filter { manager.fileExists(atPath: $0.path(percentEncoded: false)) }
            .map { RelatedFile(url: $0, size: measure($0)) }

        // A sandboxed app keeps its data in a container. macOS asks the user
        // before another app may look inside one, so only note that it
        // exists; its size stays unknown.
        let container = library.appending(path: "Containers/\(bundleID)")
        if manager.fileExists(atPath: container.path(percentEncoded: false)) {
            files.append(RelatedFile(url: container, size: nil))
        }
        return files
    }

    private nonisolated static func measure(_ url: URL) -> UInt64? {
        var isDirectory: ObjCBool = false
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return size(of: url) }
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
    }
}
