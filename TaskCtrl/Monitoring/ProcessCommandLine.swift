import Darwin
import Foundation

enum ProcessCommandLine {
    /// The command a process was started with: the full path of what it
    /// runs, then its arguments, quoted so the line can be pasted into a
    /// shell. Nil when the system does not disclose it, which is the case
    /// for other users' processes and for one that has quit.
    static func read(pid: pid_t) -> String? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        // Layout: the argument count, the executable's path, padding zeros,
        // then the arguments (the first is the name it was called by) and
        // the environment, each ending in a zero.
        let count = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size

        func nextString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }

        guard let executable = nextString(), !executable.isEmpty else { return nil }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < count, let argument = nextString() {
            arguments.append(argument)
        }
        // The path says more than the name the process was called by.
        return ([executable] + arguments.dropFirst()).map(quoted).joined(separator: " ")
    }

    /// Wraps an argument in single quotes unless every character is safe in a shell as it is.
    private static func quoted(_ argument: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
