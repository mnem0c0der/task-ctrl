import Foundation
import Security

enum CodeSigning {
    /// Team ID this binary was signed with; nil for unsigned or ad-hoc builds.
    static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty,
              team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return team
    }

    /// Requirement that the other end of an XPC connection is the given binary
    /// signed by the same team as us. The app and the helper use it on each
    /// other, so nothing else on the machine can talk to the root helper.
    static func peerRequirement(identifier: String) -> String? {
        guard let team = ownTeamIdentifier() else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }
}
