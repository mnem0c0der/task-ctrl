import Foundation

/// Thin wrapper around `launchctl`, the command-line front end of launchd.
enum Launchd {
    /// The launchd domain of the logged-in user's graphical session.
    static var userDomain: String { "gui/\(getuid())" }
    static let systemDomain = "system"

    struct DomainState: Sendable {
        /// Process ids of the services running right now, by label.
        var running: [String: Int32] = [:]
        /// Services launchd currently has loaded, running or not.
        var loaded: Set<String> = []
        /// Services launchd has an explicit on/off switch for; true means off.
        var disabled: [String: Bool] = [:]
    }

    /// Which services of a domain run right now and which are switched off.
    static func state(ofDomain domain: String) -> DomainState {
        var state = DomainState()

        // Lines in the "services" block read "<pid> <last exit status> <label>";
        // a pid of 0 means loaded but not running.
        var inServices = false
        for line in run(["print", domain]).output.split(separator: "\n") {
            if line.hasPrefix("\tservices = {") {
                inServices = true
            } else if inServices {
                if line.hasPrefix("\t}") { break }
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.count == 3, let pid = Int32(fields[0]) {
                    state.loaded.insert(String(fields[2]))
                    if pid > 0 { state.running[String(fields[2])] = pid }
                }
            }
        }

        // Lines read `"<label>" => disabled` or `=> enabled`.
        for line in run(["print-disabled", domain]).output.split(separator: "\n") {
            let parts = line.components(separatedBy: "\" => ")
            guard parts.count == 2, let quote = parts[0].firstIndex(of: "\"") else { continue }
            let label = String(parts[0][parts[0].index(after: quote)...])
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            state.disabled[label] = value == "disabled" || value == "true"
        }
        return state
    }

    /// Runs `launchctl` and waits for it. Blocking; call off the main thread.
    static func run(_ arguments: [String]) -> (status: Int32, output: String) {
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
        // Read before waiting: a full pipe would otherwise block the tool.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Label and command line from a launchd property list.
    static func readPlist(at path: String) -> (label: String, command: [String], disabled: Bool) {
        let plist = (NSDictionary(contentsOfFile: path) as? [String: Any]) ?? [:]
        let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var command = plist["ProgramArguments"] as? [String] ?? []
        if let program = plist["Program"] as? String {
            command = [program] + command.dropFirst()
        }
        return (plist["Label"] as? String ?? fallback, command, plist["Disabled"] as? Bool ?? false)
    }
}
