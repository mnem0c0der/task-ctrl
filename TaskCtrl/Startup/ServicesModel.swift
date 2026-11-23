import Foundation
import Observation

/// A background service registered with launchd through a property list.
struct ServiceItem: Identifiable, Sendable, Equatable {
    let plistPath: String
    let label: String
    /// Executable and its arguments.
    let command: [String]
    /// Folder the property list lives in, e.g. "/Library/LaunchDaemons".
    let group: String
    let isDaemon: Bool
    /// "system" or "gui/<uid>".
    let domain: String
    let isDisabled: Bool
    /// Process id when the service is running right now.
    let pid: Int32?
    /// Loaded into launchd: it may be idle, waiting to be started on demand.
    let isLoaded: Bool
    /// Third-party folders sort before the system's own.
    let rank: Int

    var id: String { plistPath }
    var isRunning: Bool { pid != nil }
    var program: String { command.first ?? "" }

    var kind: String {
        isDaemon ? "System daemon" : (group.hasPrefix("/Users/") ? "User agent" : "Agent")
    }

    var state: String {
        if let pid { return "Running (pid \(pid))" }
        if isDisabled { return "Disabled" }
        return isLoaded ? "Loaded, starts on demand" : "Stopped"
    }
}

@MainActor
@Observable
final class ServicesModel {
    private(set) var items: [ServiceItem] = []
    private(set) var isLoading = false

    func load() async {
        isLoading = true
        items = await Task.detached(priority: .userInitiated) { Self.readItems() }.value
        isLoading = false
    }

    /// Starts, stops or restarts a service, asking for administrator rights
    /// when it is a system one, then re-reads the list.
    func perform(_ action: ServiceAction, for service: ServiceItem) async throws {
        try await ServiceController.perform(
            action,
            label: service.label,
            plistPath: service.plistPath,
            isSystem: service.isDaemon
        )
        // launchd needs a moment before the new state shows up.
        try? await Task.sleep(for: .milliseconds(600))
        await load()
    }

    private nonisolated static func readItems() -> [ServiceItem] {
        let user = Launchd.state(ofDomain: Launchd.userDomain)
        let system = Launchd.state(ofDomain: Launchd.systemDomain)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)

        // Daemons run in the system domain, agents in the user's session.
        let sources: [(directory: String, isDaemon: Bool)] = [
            ("/Library/LaunchDaemons", true),
            ("/Library/LaunchAgents", false),
            (home + "Library/LaunchAgents", false),
            ("/System/Library/LaunchDaemons", true),
            ("/System/Library/LaunchAgents", false),
        ]

        var items: [ServiceItem] = []
        for (rank, source) in sources.enumerated() {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: source.directory)) ?? []
            let state = source.isDaemon ? system : user
            for name in names where name.hasSuffix(".plist") {
                let path = source.directory + "/" + name
                let plist = Launchd.readPlist(at: path)
                items.append(ServiceItem(
                    plistPath: path,
                    label: plist.label,
                    command: plist.command,
                    group: source.directory,
                    isDaemon: source.isDaemon,
                    domain: source.isDaemon ? Launchd.systemDomain : Launchd.userDomain,
                    isDisabled: state.disabled[plist.label] ?? plist.disabled,
                    pid: state.running[plist.label],
                    isLoaded: state.loaded.contains(plist.label),
                    rank: rank
                ))
            }
        }
        return items
    }
}
