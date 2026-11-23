import Foundation

/// Per-process network throughput.
///
/// macOS has no public API for this, so it comes from `nettop`, the system's
/// own tool, kept running in logging mode. Every couple of seconds it prints
/// cumulative byte counts per process; consecutive printouts give the rate.
/// Its output is buffered, so the figures can trail reality by a few seconds.
final class ProcessNetworkMonitor: @unchecked Sendable {
    struct Rate: Sendable {
        /// Bytes per second.
        var received: Double
        var sent: Double
    }

    private static let interval = 2.0

    private let lock = NSLock()
    private var rates: [pid_t: Rate] = [:]
    private var process: Process?
    /// Never written to; it only keeps nettop's stdin open.
    private let input = Pipe()

    // Parser state; only touched from the pipe's read callback.
    private var pending = Data()
    private var current: [pid_t: (received: UInt64, sent: UInt64)] = [:]
    private var previous: [pid_t: (received: UInt64, sent: UInt64)]?

    /// Latest rates; empty until two printouts have arrived or if nettop is unavailable.
    var latest: [pid_t: Rate] {
        lock.withLock { rates }
    }

    func start() {
        guard process == nil else { return }
        let nettop = Process()
        nettop.executableURL = URL(filePath: "/bin/sh")
        // -P per process, -L 0 log forever, -x raw numbers, -n no DNS lookups.
        //
        // nettop must get a stdin that stays open: handed /dev/null it reads
        // end-of-file in a tight loop and burns more than a whole core. Hence
        // the pipe below, and `<&0`, without which the shell would give a
        // background job /dev/null.
        //
        // The shell around it exists only to stop nettop when this app goes
        // away for any reason, including a crash: left alone it would keep
        // running in the background.
        nettop.arguments = [
            "-c",
            """
            /usr/bin/nettop -P -L 0 -s \(Int(Self.interval)) -n -x <&0 &
            child=$!
            trap 'kill $child 2>/dev/null; exit 0' TERM INT
            while kill -0 $PPID 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 2; done
            kill $child 2>/dev/null
            """,
        ]
        let output = Pipe()
        nettop.standardInput = input
        nettop.standardOutput = output
        nettop.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        nettop.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            self?.lock.withLock { self?.rates = [:] }
        }
        do {
            try nettop.run()
            process = nettop
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
        }
    }

    deinit {
        process?.terminate()
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            parse(line)
        }
    }

    /// Columns are `time,name.pid,interface,state,bytes_in,bytes_out,…`, e.g.
    /// `12:27:11.639220,apsd.138,,,295452,591675,0,…`; each printout starts
    /// with a header line whose first field is `time`.
    private func parse(_ line: String) {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 6 else { return }
        if fields[0] == "time" {
            finishPrintout()
            return
        }
        let identity = fields[1]
        let received = fields[4]
        let sent = fields[5]
        // The name itself may contain dots; the pid follows the last one.
        guard let dot = identity.lastIndex(of: "."),
              let pid = pid_t(identity[identity.index(after: dot)...]),
              let received = UInt64(received),
              let sent = UInt64(sent)
        else { return }
        current[pid] = (received, sent)
    }

    private func finishPrintout() {
        guard !current.isEmpty else { return }
        if let previous {
            var fresh: [pid_t: Rate] = [:]
            for (pid, now) in current {
                guard let before = previous[pid],
                      now.received >= before.received, now.sent >= before.sent
                else { continue }
                fresh[pid] = Rate(
                    received: Double(now.received - before.received) / Self.interval,
                    sent: Double(now.sent - before.sent) / Self.interval
                )
            }
            lock.withLock { rates = fresh }
        }
        previous = current
        current = [:]
    }
}
