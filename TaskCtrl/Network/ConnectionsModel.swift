import Foundation
import Observation

/// One open socket of a process.
struct Connection: Identifiable, Sendable, Equatable {
    enum Family: String, Sendable {
        case ipv4 = "IPv4"
        case ipv6 = "IPv6"
        /// A Unix domain socket: talk between programs on this Mac.
        case unix = "Unix"
    }

    let pid: pid_t
    let command: String
    let uid: uid_t
    let user: String
    /// File descriptor with its access mode, e.g. "31u".
    let descriptor: String
    let family: Family
    /// "TCP", "UDP" or empty for Unix sockets.
    let transport: String
    /// "LISTEN", "ESTABLISHED", "BOUND", "CONNECTED", "IPC", or another TCP state.
    let state: String
    let local: String
    let remote: String?

    var id: String { "\(pid)-\(descriptor)" }
    var isIPC: Bool { family == .unix }
    var isListening: Bool { state == "LISTEN" }
    var isConnected: Bool { !isIPC && remote != nil }

    /// Reachable from other machines: bound to every interface or to a public address.
    var isPublic: Bool {
        guard !isIPC, let host = Endpoint(local)?.host else { return false }
        return host == "*" || host == "::" || Endpoint.reach(of: host) == .internet
    }

    /// Well-known name of the port in use, e.g. "HTTPS".
    var service: String? {
        guard !isIPC, let port = (remote.flatMap(Endpoint.init) ?? Endpoint(local))?.port else {
            return nil
        }
        return Endpoint.serviceName(port: port, transport: transport)
    }

    /// Who is on the other end, or who could be.
    var exposure: String {
        if isIPC { return "This Mac only" }
        if let remoteHost = remote.flatMap(Endpoint.init)?.host {
            return Endpoint.reach(of: remoteHost).rawValue
        }
        guard let host = Endpoint(local)?.host else { return "Unknown" }
        if host == "*" || host == "::" { return "All interfaces" }
        return Endpoint.reach(of: host).rawValue
    }
}

/// A "host:port" pair as lsof prints it, e.g. "192.168.1.24:52206" or "[::1]:7000".
struct Endpoint {
    enum Reach: String {
        case loopback = "This Mac only"
        case localNetwork = "Local network"
        case internet = "Internet"
    }

    let host: String
    let port: Int?

    init?(_ text: String) {
        guard let colon = text.lastIndex(of: ":") else { return nil }
        host = text[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        port = Int(text[text.index(after: colon)...])
    }

    static func reach(of host: String) -> Reach {
        let host = host.lowercased()
        if host.hasPrefix("127.") || host == "::1" || host == "localhost" { return .loopback }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.")
            || host.hasPrefix("fe80") || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return .localNetwork
        }
        // 172.16.0.0 – 172.31.255.255
        let parts = host.split(separator: ".")
        if parts.count == 4, parts[0] == "172", let second = Int(parts[1]), (16...31).contains(second) {
            return .localNetwork
        }
        return .internet
    }

    static func serviceName(port: Int, transport: String) -> String? {
        switch port {
        case 443: return "HTTPS"
        case 80: return "HTTP"
        case 53: return "DNS"
        case 5353: return "mDNS (Bonjour)"
        case 5223: return "Apple Push"
        case 22: return "SSH"
        case 123: return "NTP"
        default: break
        }
        guard (1...65535).contains(port),
              let entry = getservbyport(Int32(UInt16(port).bigEndian), transport.lowercased())
        else { return nil }
        return String(cString: entry.pointee.s_name).uppercased()
    }
}

/// Lists open sockets with `lsof`, the system's own tool for this.
/// On its own it sees only the current user's processes; with the root
/// helper installed it sees everyone's.
@MainActor
@Observable
final class ConnectionsModel {
    private(set) var connections: [Connection] = []
    private(set) var hasLoaded = false
    /// True when the list covers every process, not just the user's own.
    private(set) var coversAllUsers = false
    /// When each socket was first seen, for the "observed for" figure.
    private(set) var firstSeen: [Connection.ID: Date] = [:]

    func refresh() async {
        let found: [Connection]
        if let privileged = await HelperClient.shared.openSockets(), !privileged.isEmpty {
            found = await Task.detached(priority: .utility) {
                Self.parse(String(decoding: privileged, as: UTF8.self))
            }.value
            coversAllUsers = true
        } else {
            found = await Task.detached(priority: .utility) {
                Self.parse(String(decoding: SocketListing.run(), as: UTF8.self))
            }.value
            coversAllUsers = false
        }
        let now = Date()
        var seen: [Connection.ID: Date] = [:]
        for connection in found {
            seen[connection.id] = firstSeen[connection.id] ?? now
        }
        firstSeen = seen
        connections = found
        hasLoaded = true
    }

    // MARK: - Parsing

    /// Each line is a one-letter field name and its value. Process fields
    /// (p, c, u, L) come once, followed by a group per open file that starts
    /// with its descriptor (f).
    static nonisolated func parse(_ text: String) -> [Connection] {
        var connections: [Connection] = []

        var pid: pid_t = 0
        var command = ""
        var uid: uid_t = 0
        var user = ""

        var descriptor: String?
        var access = ""
        var type = ""
        var transport = ""
        var name = ""
        var tcpState: String?

        func flush() {
            defer {
                descriptor = nil
                access = ""
                type = ""
                transport = ""
                name = ""
                tcpState = nil
            }
            guard let descriptor else { return }
            let family: Connection.Family
            switch type {
            case "IPv4": family = .ipv4
            case "IPv6": family = .ipv6
            case "unix": family = .unix
            default: return
            }

            var local = name
            var remote: String?
            if let arrow = name.range(of: "->") {
                local = String(name[..<arrow.lowerBound])
                remote = String(name[arrow.upperBound...])
            }

            let state: String
            if family == .unix {
                state = "IPC"
                if local.isEmpty { local = "(unnamed)" }
            } else if transport == "TCP" {
                state = tcpState ?? (remote == nil ? "CLOSED" : "ESTABLISHED")
            } else {
                state = remote == nil ? "BOUND" : "CONNECTED"
            }

            connections.append(Connection(
                pid: pid,
                command: command,
                uid: uid,
                user: user,
                descriptor: descriptor + access,
                family: family,
                transport: family == .unix ? "" : transport,
                state: state,
                local: local,
                remote: remote
            ))
        }

        for line in text.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                flush()
                pid = pid_t(value) ?? 0
                command = ""
                user = ""
            case "c": command = value
            case "u": uid = uid_t(value) ?? 0
            case "L": user = value
            case "f":
                flush()
                descriptor = value
            case "a": access = value.trimmingCharacters(in: .whitespaces)
            case "t": type = value
            case "P": transport = value
            case "n": name = value
            case "T":
                if value.hasPrefix("ST=") { tcpState = String(value.dropFirst(3)) }
            default: break
            }
        }
        flush()
        return connections
    }
}
