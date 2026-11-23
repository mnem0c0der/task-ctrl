import Foundation
import Security

/// Proof that the person at the keyboard approved an administrator action.
///
/// The app asks macOS for the right, which shows the system's own password
/// dialog; the root helper refuses to change services unless it receives a
/// valid proof. The password itself never passes through this app.
final class AdminAuthorization: @unchecked Sendable {
    /// The standard macOS right for running something as administrator.
    private static let rightName = "system.privilege.admin"

    enum Failure: LocalizedError {
        case cancelled
        case denied(OSStatus)

        var errorDescription: String? {
            switch self {
            case .cancelled: "The request was cancelled."
            case .denied(let status): "Administrator rights were not granted (error \(status))."
            }
        }
    }

    private let reference: AuthorizationRef
    /// Portable form of the proof, handed to the helper.
    let externalForm: Data

    /// Shows the system authentication dialog and waits for the answer.
    /// Blocking; call off the main thread.
    init(prompt: String) throws {
        var reference: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &reference)
        guard status == errAuthorizationSuccess, let reference else { throw Failure.denied(status) }

        status = Self.copyRight(
            reference, prompt: prompt, flags: [.interactionAllowed, .extendRights, .preAuthorize]
        )
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(reference, [.destroyRights])
            throw status == errAuthorizationCanceled ? Failure.cancelled : Failure.denied(status)
        }

        var form = AuthorizationExternalForm()
        status = AuthorizationMakeExternalForm(reference, &form)
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(reference, [.destroyRights])
            throw Failure.denied(status)
        }
        self.reference = reference
        externalForm = withUnsafeBytes(of: &form) { Data($0) }
    }

    deinit {
        // Forget the approval right away, so every action asks again.
        AuthorizationFree(reference, [.destroyRights])
    }

    /// Checks a proof received from another process. Never shows a dialog.
    static func isValid(externalForm data: Data) -> Bool {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form) { _ = data.copyBytes(to: $0) }
        var reference: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &reference) == errAuthorizationSuccess,
              let reference
        else { return false }
        defer { AuthorizationFree(reference, []) }
        return copyRight(reference, prompt: nil, flags: [.extendRights]) == errAuthorizationSuccess
    }

    private static func copyRight(
        _ reference: AuthorizationRef, prompt: String?, flags: AuthorizationFlags
    ) -> OSStatus {
        rightName.withCString { name in
            var right = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &right) { rightPointer in
                var rights = AuthorizationRights(count: 1, items: rightPointer)
                guard let prompt else {
                    return AuthorizationCopyRights(reference, &rights, nil, flags, nil)
                }
                // The text shown in the dialog above the password field.
                return prompt.withCString { text in
                    kAuthorizationEnvironmentPrompt.withCString { key in
                        var item = AuthorizationItem(
                            name: key,
                            valueLength: strlen(text),
                            value: UnsafeMutableRawPointer(mutating: text),
                            flags: 0
                        )
                        return withUnsafeMutablePointer(to: &item) { itemPointer in
                            var environment = AuthorizationEnvironment(count: 1, items: itemPointer)
                            return AuthorizationCopyRights(reference, &rights, &environment, flags, nil)
                        }
                    }
                }
            }
        }
    }
}
