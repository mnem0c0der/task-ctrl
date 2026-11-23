import Darwin
import Foundation
import SystemConfiguration

/// What the system's user database says about an account.
struct UserAccount: Sendable {
    let uid: uid_t
    let name: String
    let fullName: String
    let groupID: gid_t
    let groupName: String
    let home: String
    let shell: String
    let isAdministrator: Bool

    /// Accounts below 500 belong to the system and its services, not to people.
    var isPerson: Bool { uid >= 500 }

    init?(uid: uid_t) {
        guard let entry = getpwuid(uid)?.pointee else { return nil }
        self.uid = uid
        name = String(cString: entry.pw_name)
        fullName = entry.pw_gecos.map { String(cString: $0) } ?? ""
        groupID = entry.pw_gid
        groupName = getgrgid(entry.pw_gid).map { String(cString: $0.pointee.gr_name) } ?? String(entry.pw_gid)
        home = String(cString: entry.pw_dir)
        shell = String(cString: entry.pw_shell)

        // Administrators are the members of group 80 ("admin").
        var groups = [Int32](repeating: 0, count: 128)
        var count = Int32(groups.count)
        getgrouplist(entry.pw_name, Int32(bitPattern: entry.pw_gid), &groups, &count)
        isAdministrator = groups.prefix(Int(max(count, 0))).contains(80)
    }

    /// The user sitting at the screen right now, if anyone is logged in there.
    static var consoleUID: uid_t? {
        var uid: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil else { return nil }
        return uid
    }
}
