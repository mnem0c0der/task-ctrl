import Foundation

/// The app's end of the XPC connection to the root helper.
actor HelperClient {
    static let shared = HelperClient()

    enum HelperError: LocalizedError {
        case unavailable
        case posix(Int32)

        var errorDescription: String? {
            switch self {
            case .unavailable: "The helper is not running."
            case .posix(let code): String(cString: strerror(code))
            }
        }
    }

    private var enabled = false
    private var connection: NSXPCConnection?
    /// Identifies the current connection, so a late invalidation of an old one is ignored.
    private var generation = 0
    /// Version reported by the helper behind the current connection.
    private var helperVersion: Int?
    /// After a failed call, leave the helper alone for a while instead of retrying every second.
    private var retryAfter: ContinuousClock.Instant?

    /// Told by `HelperManager` whether the helper is installed and approved.
    func setEnabled(_ value: Bool) {
        enabled = value
        retryAfter = nil
        if !value { dropConnection() }
    }

    /// Resource counters for every process, or nil when the helper cannot be
    /// reached or comes from a different build.
    func processUsage() async -> [pid_t: ProcessUsageRecord]? {
        guard enabled, retryAfter.map({ ContinuousClock.now >= $0 }) ?? true else { return nil }
        // A helper from another build packs its records differently.
        if helperVersion == nil { helperVersion = await version() }
        guard helperVersion == HelperConstants.version else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            guard let proxy = proxy(onError: { _ in continuation.resume(returning: nil) }) else {
                return continuation.resume(returning: nil)
            }
            proxy.getProcessUsage { continuation.resume(returning: $0) }
        }
        guard let data else {
            failed()
            return nil
        }
        var usage: [pid_t: ProcessUsageRecord] = [:]
        for record in ProcessUsageRecord.decode(data) { usage[record.pid] = record }
        return usage
    }

    /// Open sockets of all processes as raw lsof output, or nil without a
    /// matching helper.
    func openSockets() async -> Data? {
        guard await isReady else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            guard let proxy = proxy(onError: { _ in continuation.resume(returning: nil) }) else {
                return continuation.resume(returning: nil)
            }
            proxy.getOpenSockets { continuation.resume(returning: $0) }
        }
        if data == nil { failed() }
        return data
    }

    /// True when the helper is installed and matches this build.
    var isReady: Bool {
        get async {
            guard enabled else { return false }
            if helperVersion == nil { helperVersion = await version() }
            return helperVersion == HelperConstants.version
        }
    }

    /// Asks the helper to change a system service; returns launchctl's verdict.
    func controlService(
        _ action: ServiceAction, label: String, plistPath: String, authorization: Data
    ) async throws -> (status: Int32, output: String) {
        guard await isReady else { throw HelperError.unavailable }
        let result: (Int32, String)? = await withCheckedContinuation { continuation in
            guard let proxy = proxy(onError: { _ in continuation.resume(returning: nil) }) else {
                return continuation.resume(returning: nil)
            }
            proxy.controlService(
                action.rawValue, label: label, plistPath: plistPath, authorization: authorization
            ) { status, output in
                continuation.resume(returning: (status, output))
            }
        }
        guard let result else {
            failed()
            throw HelperError.unavailable
        }
        return result
    }

    func sendSignal(_ signal: Int32, to pid: pid_t) async throws {
        guard enabled else { throw HelperError.unavailable }
        let result: Int32? = await withCheckedContinuation { continuation in
            guard let proxy = proxy(onError: { _ in continuation.resume(returning: nil) }) else {
                return continuation.resume(returning: nil)
            }
            proxy.sendSignal(signal, toProcess: pid) { continuation.resume(returning: $0) }
        }
        guard let result else {
            failed()
            throw HelperError.unavailable
        }
        if result != 0 { throw HelperError.posix(result) }
    }

    /// Version of the installed helper, or nil when it cannot be reached.
    func version() async -> Int? {
        guard enabled else { return nil }
        return await withCheckedContinuation { continuation in
            guard let proxy = proxy(onError: { _ in continuation.resume(returning: nil) }) else {
                return continuation.resume(returning: nil)
            }
            proxy.getVersion { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Connection

    /// XPC calls exactly one of the reply block or `onError`, never both.
    private func proxy(onError: @escaping @Sendable (Error) -> Void) -> HelperProtocol? {
        if connection == nil {
            // Refuse to talk to anything but our own helper.
            guard let requirement = CodeSigning.peerRequirement(
                identifier: HelperConstants.helperIdentifier
            ) else { return nil }
            let new = NSXPCConnection(
                machServiceName: HelperConstants.machServiceName,
                options: .privileged
            )
            new.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            new.setCodeSigningRequirement(requirement)
            generation += 1
            let current = generation
            new.invalidationHandler = { @Sendable [weak self] in
                Task { await self?.connectionInvalidated(generation: current) }
            }
            new.resume()
            connection = new
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? HelperProtocol
    }

    private func failed() {
        dropConnection()
        retryAfter = ContinuousClock.now + .seconds(5)
    }

    private func dropConnection() {
        connection?.invalidationHandler = nil
        connection?.invalidate()
        connection = nil
        helperVersion = nil
    }

    private func connectionInvalidated(generation old: Int) {
        if generation == old {
            connection = nil
            helperVersion = nil
        }
    }
}
