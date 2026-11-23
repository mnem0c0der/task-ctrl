import Foundation

/// Starts, stops, enables and disables launchd services.
///
/// Services of the user's own session are handled directly. System services
/// need administrator rights: macOS asks for the password, and the root
/// helper carries the change out once it has seen the approval.
enum ServiceController {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Does nothing and throws nothing when the user cancels the password dialog.
    static func perform(
        _ action: ServiceAction, label: String, plistPath: String, isSystem: Bool
    ) async throws {
        if isSystem {
            try await performAsAdministrator(action, label: label, plistPath: plistPath)
        } else {
            let result = await Task.detached {
                run(action, target: Launchd.userDomain, label: label, plistPath: plistPath)
            }.value
            if result.status != 0 { throw Failure(message: describe(result)) }
        }
    }

    private static func performAsAdministrator(
        _ action: ServiceAction, label: String, plistPath: String
    ) async throws {
        guard await HelperClient.shared.isReady else {
            throw Failure(message: "Changing system services needs the TaskCtrl helper. Install or update it in Settings (⌘,).")
        }
        let prompt = "TaskCtrl wants to \(action.verb) the system service “\(label)”."
        let authorization: AdminAuthorization
        do {
            // The dialog blocks until answered, so keep it off the main thread.
            authorization = try await Task.detached { try AdminAuthorization(prompt: prompt) }.value
        } catch AdminAuthorization.Failure.cancelled {
            return
        }
        let result = try await HelperClient.shared.controlService(
            action, label: label, plistPath: plistPath, authorization: authorization.externalForm
        )
        if result.status != 0 {
            throw Failure(message: describe((result.status, result.output)))
        }
    }

    /// The same launchctl calls the helper makes for system services.
    private static func run(
        _ action: ServiceAction, target domain: String, label: String, plistPath: String
    ) -> (status: Int32, output: String) {
        let service = "\(domain)/\(label)"
        switch action {
        case .start:
            // Loading fails harmlessly when the service is already loaded.
            _ = Launchd.run(["bootstrap", domain, plistPath])
            return Launchd.run(["kickstart", service])
        case .stop:
            return Launchd.run(["bootout", service])
        case .restart:
            return Launchd.run(["kickstart", "-k", service])
        case .enable:
            return Launchd.run(["enable", service])
        case .disable:
            return Launchd.run(["disable", service])
        }
    }

    private static func describe(_ result: (status: Int32, output: String)) -> String {
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "launchctl exited with status \(result.status)." : text
    }
}
