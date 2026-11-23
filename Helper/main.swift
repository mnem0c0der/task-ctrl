import Darwin
import Foundation

/// Root daemon started on demand by launchd when the app connects.

/// Runs launchctl for the one privileged thing the app may ask for:
/// changing a system service. Everything is checked here, on the root side;
/// nothing the app sends is trusted as is.
enum SystemServices {
    private static let allowedFolders = ["/Library/LaunchDaemons/", "/System/Library/LaunchDaemons/"]

    static func perform(_ action: ServiceAction, label: String, plistPath: String) -> (Int32, String) {
        // Labels are reverse-DNS names; anything else could smuggle in
        // another launchctl target.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !label.isEmpty, label.count < 256,
              label.unicodeScalars.allSatisfy(allowed.contains)
        else { return (EINVAL, "Invalid service label.") }

        let service = "system/\(label)"
        switch action {
        case .start:
            // Only property lists from the daemon folders may be loaded as root.
            let path = (plistPath as NSString).standardizingPath
            guard path.hasSuffix(".plist"), allowedFolders.contains(where: path.hasPrefix) else {
                return (EINVAL, "The service's property list is not in a system daemon folder.")
            }
            // Loading fails harmlessly when the service is already loaded.
            _ = run(["bootstrap", "system", path])
            return run(["kickstart", service])
        case .stop:
            return run(["bootout", service])
        case .restart:
            return run(["kickstart", "-k", service])
        case .enable:
            return run(["enable", service])
        case .disable:
            return run(["disable", service])
        }
    }

    private static func run(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

final class HelperService: NSObject, HelperProtocol {
    func controlService(
        _ action: Int, label: String, plistPath: String, authorization: Data,
        reply: @escaping @Sendable (Int32, String) -> Void
    ) {
        IdleWatch.shared.touch()
        // No valid approval from the user, no change.
        guard AdminAuthorization.isValid(externalForm: authorization) else {
            return reply(EPERM, "Administrator approval is missing or no longer valid.")
        }
        guard let action = ServiceAction(rawValue: action) else {
            return reply(EINVAL, "Unknown action.")
        }
        let result = SystemServices.perform(action, label: label, plistPath: plistPath)
        reply(result.0, result.1)
    }

    func getOpenSockets(reply: @escaping @Sendable (Data) -> Void) {
        IdleWatch.shared.touch()
        // lsof takes a moment; keep the connection's queue free meanwhile.
        DispatchQueue.global(qos: .utility).async {
            reply(SocketListing.run())
        }
    }

    func getVersion(reply: @escaping @Sendable (Int) -> Void) {
        IdleWatch.shared.touch()
        reply(HelperConstants.version)
    }

    func getProcessUsage(reply: @escaping @Sendable (Data) -> Void) {
        IdleWatch.shared.touch()
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let found = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))
        guard found > 0 else { return reply(Data()) }

        let records = pids.prefix(found).compactMap { pid in
            pid > 0 ? ProcessUsageRecord.read(pid: pid) : nil
        }
        reply(ProcessUsageRecord.encode(records))
    }

    func sendSignal(_ signal: Int32, toProcess pid: Int32, reply: @escaping @Sendable (Int32) -> Void) {
        IdleWatch.shared.touch()
        // Only the two signals the app offers, and never the kernel or launchd.
        guard signal == SIGTERM || signal == SIGKILL, pid > 1, pid != getpid() else {
            return reply(EPERM)
        }
        reply(kill(pid, signal) == 0 ? 0 : errno)
    }
}

/// Tracks when the app last asked for something. The app polls every second
/// while it is open, so a quiet spell means it is gone and the daemon should
/// not linger as root; launchd starts it again on demand.
final class IdleWatch: @unchecked Sendable {
    static let shared = IdleWatch()
    static let timeout: TimeInterval = 30

    private let lock = NSLock()
    private var lastActivity = Date()
    private var timer: DispatchSourceTimer?

    func touch() {
        lock.withLock { lastActivity = Date() }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [self] in
            let idle = lock.withLock { Date().timeIntervalSince(lastActivity) }
            if idle > Self.timeout { exit(EXIT_SUCCESS) }
        }
        timer.resume()
        self.timer = timer
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        IdleWatch.shared.touch()
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }
}

// Without a team identity there is no way to tell the real app from an
// impostor, so refuse to serve at all.
guard let requirement = CodeSigning.peerRequirement(identifier: HelperConstants.appIdentifier) else {
    FileHandle.standardError.write(Data("TaskCtrlHelper: not signed with a team identity, exiting\n".utf8))
    exit(EXIT_FAILURE)
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = delegate
listener.resume()
IdleWatch.shared.start()
dispatchMain()
