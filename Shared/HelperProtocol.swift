import Darwin
import Foundation

enum HelperConstants {
    static let appIdentifier = "dev.taskctrl.TaskCtrl"
    static let helperIdentifier = "dev.taskctrl.TaskCtrl.helper"
    static let machServiceName = "dev.taskctrl.helper"
    static let daemonPlistName = "dev.taskctrl.helper.plist"
    /// Bump whenever the protocol or `ProcessUsageRecord` changes: the app
    /// ignores usage data from a helper with a different version, because the
    /// record layout would not match.
    static let version = 5
}

/// What the root helper does on the app's behalf. Kept deliberately small:
/// everything here runs with full system rights.
@objc protocol HelperProtocol {
    func getVersion(reply: @escaping @Sendable (Int) -> Void)

    /// Resource counters of every process, as packed `ProcessUsageRecord`s.
    func getProcessUsage(reply: @escaping @Sendable (Data) -> Void)

    /// Starts, stops, enables or disables a system service. `action` is a
    /// `ServiceAction` raw value; `authorization` must prove the user just
    /// approved an administrator action. Replies with launchctl's exit status
    /// and output. (Since version 4.)
    func controlService(
        _ action: Int, label: String, plistPath: String, authorization: Data,
        reply: @escaping @Sendable (Int32, String) -> Void
    )

    /// Open sockets of every process: the raw field output of `lsof`, which
    /// the app parses the same way as its own, unprivileged run. Takes no
    /// input, so there is nothing for a caller to influence. (Since version 5.)
    func getOpenSockets(reply: @escaping @Sendable (Data) -> Void)

    /// Sends SIGTERM or SIGKILL. Replies with 0 or an errno value.
    func sendSignal(_ signal: Int32, toProcess pid: Int32, reply: @escaping @Sendable (Int32) -> Void)
}

enum SocketListing {
    static let tool = "/usr/sbin/lsof"
    /// -n -P: no name lookups, numeric ports. +c 0: full command names.
    /// -i -U: internet and Unix sockets. -F: one field per line.
    static let arguments = ["-nP", "+c", "0", "-i", "-U", "-FpcuLfatPnT"]

    /// Runs lsof and returns what it printed. Blocking.
    static func run() -> Data {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return Data() }
        // Read before waiting: a full pipe would otherwise block the tool.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}

/// What can be done to a launchd service.
enum ServiceAction: Int, Sendable {
    /// Load the service if needed and start it now.
    case start
    /// Unload it: it stops and stays stopped until started again or the next boot or login.
    case stop
    /// Stop the running instance and start a fresh one.
    case restart
    /// Let launchd start it automatically again.
    case enable
    /// Keep launchd from starting it automatically.
    case disable

    var verb: String {
        switch self {
        case .start: "start"
        case .stop: "stop"
        case .restart: "restart"
        case .enable: "enable"
        case .disable: "disable"
        }
    }
}

/// Cumulative resource counters of one process. Fixed layout, so a whole
/// process table travels from the helper as one blob.
struct ProcessUsageRecord: Sendable {
    var pid: Int32
    /// Zero when the thread count could not be read.
    var threads: Int32 = 0
    /// User + system time in mach absolute time units.
    var cpuTime: UInt64 = 0
    var footprint: UInt64 = 0
    var diskRead: UInt64 = 0
    var diskWritten: UInt64 = 0
    /// Energy the kernel attributes to the process, nanojoules.
    var energy: UInt64 = 0

    /// Reads the counters of one process. Fails for processes of other users
    /// unless the caller is root, which is why the helper runs this too.
    static func read(pid: pid_t) -> ProcessUsageRecord? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard result == 0 else { return nil }

        var record = ProcessUsageRecord(
            pid: pid,
            cpuTime: info.ri_user_time &+ info.ri_system_time,
            footprint: info.ri_phys_footprint,
            diskRead: info.ri_diskio_bytesread,
            diskWritten: info.ri_diskio_byteswritten,
            energy: info.ri_energy_nj
        )
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size {
            record.threads = task.pti_threadnum
        }
        return record
    }

    static func encode(_ records: [ProcessUsageRecord]) -> Data {
        records.withUnsafeBytes { Data($0) }
    }

    static func decode(_ data: Data) -> [ProcessUsageRecord] {
        let stride = MemoryLayout<ProcessUsageRecord>.stride
        return data.withUnsafeBytes { bytes in
            (0..<bytes.count / stride).map {
                bytes.loadUnaligned(fromByteOffset: $0 * stride, as: ProcessUsageRecord.self)
            }
        }
    }
}
