import Foundation
import Observation
import Security

/// A program macOS starts on its own, described by a launchd property list.
struct StartupItem: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        /// Starts when this user logs in; installed for this user only.
        case userAgent = "User agent"
        /// Starts when any user logs in.
        case globalAgent = "Global agent"
        /// Starts at boot and runs as a system service.
        case daemon = "System daemon"
    }

    let plistPath: String
    /// The name launchd knows the item by.
    let label: String
    let kind: Kind
    /// Executable and its arguments, as written in the property list.
    let command: [String]
    var isEnabled: Bool
    /// Process id when the item is running right now.
    var pid: Int32?

    let fileSize: UInt64?
    let modified: Date?
    let created: Date?
    let owner: String?
    let permissions: Int?

    var id: String { plistPath }
    var isRunning: Bool { pid != nil }

}

@MainActor
@Observable
final class StartupItemsModel {
    private(set) var items: [StartupItem] = []
    private(set) var isLoading = false
    /// Publisher names by executable path; looked up on demand because
    /// checking a code signature is slow.
    private(set) var publishers: [String: String] = [:]

    func load() async {
        isLoading = true
        items = await Task.detached(priority: .userInitiated) { Self.readItems() }.value
        isLoading = false
    }

    /// Switches whether launchd starts the item. The change applies from the
    /// next login: a program that is already running is left alone.
    func setEnabled(_ enabled: Bool, for item: StartupItem) async throws {
        // System daemons go through the administrator prompt and the helper.
        try await ServiceController.perform(
            enabled ? .enable : .disable,
            label: item.label,
            plistPath: item.plistPath,
            isSystem: item.kind == .daemon
        )
        await load()
    }

    /// Who signed the item's executable, e.g. "Developer ID Application: Acme (ABCDE12345)".
    func loadPublisher(for item: StartupItem) {
        guard let executable = item.command.first, publishers[executable] == nil else { return }
        Task {
            let name = await Task.detached { Self.publisher(ofExecutableAt: executable) }.value
            publishers[executable] = name ?? "Unavailable"
        }
    }

    // MARK: - Reading

    private nonisolated static func readItems() -> [StartupItem] {
        let userState = Launchd.state(ofDomain: Launchd.userDomain)
        let systemState = Launchd.state(ofDomain: Launchd.systemDomain)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)

        let sources: [(directory: String, kind: StartupItem.Kind)] = [
            (home + "Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .globalAgent),
            ("/Library/LaunchDaemons", .daemon),
        ]

        var items: [StartupItem] = []
        for source in sources {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: source.directory)) ?? []
            for name in names.sorted() where name.hasSuffix(".plist") {
                let path = source.directory + "/" + name
                let plist = Launchd.readPlist(at: path)
                let label = plist.label
                let command = plist.command
                let state = source.kind == .daemon ? systemState : userState

                // launchd's own switch wins; the property list's "Disabled"
                // key only applies when launchd has no opinion.
                let enabled = !(state.disabled[label] ?? plist.disabled)

                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                let ownerName = attributes?[.ownerAccountName] as? String
                let groupName = attributes?[.groupOwnerAccountName] as? String

                items.append(StartupItem(
                    plistPath: path,
                    label: label,
                    kind: source.kind,
                    command: command,
                    isEnabled: enabled,
                    pid: state.running[label],
                    fileSize: (attributes?[.size] as? NSNumber)?.uint64Value,
                    modified: attributes?[.modificationDate] as? Date,
                    created: attributes?[.creationDate] as? Date,
                    owner: ownerName.map { "\($0):\(groupName ?? "?")" },
                    permissions: (attributes?[.posixPermissions] as? NSNumber)?.intValue
                ))
            }
        }
        return items
    }

    private nonisolated static func publisher(ofExecutableAt path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(filePath: path) as CFURL, [], &code) == errSecSuccess,
              let code
        else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let details = info as? [String: Any],
              let certificates = details[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first
        else { return nil }
        return SecCertificateCopySubjectSummary(leaf) as String?
    }
}
