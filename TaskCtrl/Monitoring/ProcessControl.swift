import Darwin
import Foundation

enum ProcessControl {
    enum Action: String, Identifiable {
        /// SIGTERM: the process is asked to exit and may clean up first.
        case quit
        /// SIGKILL: the process is stopped immediately.
        case forceQuit

        var id: Self { self }

        var signal: Int32 {
            switch self {
            case .quit: SIGTERM
            case .forceQuit: SIGKILL
            }
        }
    }

    static func send(_ action: Action, to pid: pid_t) throws {
        guard pid > 1 else { throw POSIXError(.EPERM) }
        if kill(pid, action.signal) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
    }
}
