import Foundation
import Observation
import ServiceManagement

/// Installs and removes the root helper and tracks whether macOS lets it run.
@MainActor
@Observable
final class HelperManager {
    enum State: Equatable {
        case notInstalled
        /// Registered, but the user still has to allow it in System Settings.
        case requiresApproval
        case enabled
        /// Running, but left over from an older build of the app.
        case outdated
        /// This build cannot have a helper, e.g. it is not signed with a team identity.
        case unavailable
    }

    private(set) var state: State = .notInstalled
    private(set) var lastError: String?

    private let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)

    /// An outdated helper still serves the calls it knows.
    var isEnabled: Bool { state == .enabled || state == .outdated }

    init() {
        refresh()
    }

    /// Re-reads the status; call when the app becomes active, since approval
    /// happens in System Settings.
    func refresh() {
        if CodeSigning.ownTeamIdentifier() == nil {
            state = .unavailable
        } else {
            switch service.status {
            case .enabled: state = .enabled
            case .requiresApproval: state = .requiresApproval
            default: state = .notInstalled
            }
        }
        let enabled = isEnabled
        Task {
            await HelperClient.shared.setEnabled(enabled)
            guard enabled, let version = await HelperClient.shared.version() else { return }
            if version != HelperConstants.version, state == .enabled { state = .outdated }
        }
    }

    /// Replaces a helper from an older build with the one in this app.
    func update() async {
        await uninstall()
        install()
    }

    func install() {
        lastError = nil
        do {
            try service.register()
        } catch {
            // Registering also throws when approval is merely pending; the
            // status tells the two cases apart.
            if service.status != .requiresApproval {
                lastError = error.localizedDescription
            }
        }
        refresh()
    }

    func uninstall() async {
        lastError = nil
        do {
            try await service.unregister()
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
