import AppKit
import SwiftUI

struct ProcessesView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case all = "All"
        case mine = "Mine"

        var id: Self { self }
    }

    /// A table row.
    ///
    /// In the flat list a row is identified by its position, not by the
    /// process in it. With processes as row identity, every re-sort made the
    /// table remove and re-insert rows with animation, which dominated the
    /// app's CPU use. Positional identity keeps the rows in place and only
    /// swaps their contents; it also keeps the scroll position still.
    ///
    /// In the tree a row is identified by its pid instead: which groups are
    /// expanded is remembered per row identity and has to follow the process.
    private struct Row: Identifiable {
        let id: Int
        /// What the row displays. For a group this is the total of the
        /// process and everything below it.
        let process: ProcessSample
        var descendantCount = 0
        var children: [Row]?
    }

    /// Where every process stood the last time the list was put in order,
    /// so the next ordering can start from there instead of from scratch.
    /// A class, because it is updated while the rows are being built.
    private final class OrderMemory {
        var ranks: [pid_t: Int] = [:]
        /// The sort settings the ranks were made under.
        var settings = ""
    }

    private struct PendingAction: Identifiable {
        let action: ProcessControl.Action
        let process: ProcessSample

        var id: String { "\(action.rawValue)-\(process.pid)" }
    }

    @Environment(SystemMonitor.self) private var monitor
    @Environment(HelperManager.self) private var helper
    @Environment(AppNavigation.self) private var navigation
    @State private var sortOrder = [KeyPathComparator(\Row.process.cpu, order: .reverse)]
    /// The selected process. Kept as a pid so the selection follows the
    /// process when it moves to another row.
    @State private var selection: pid_t?
    @State private var searchText = ""
    @State private var scope: Scope = .all
    @AppStorage("processDetails") private var showsDetails = false
    @AppStorage("processTree") private var showsTree = false
    @AppStorage("smoothCPUSorting") private var sortsSmoothly = true
    @AppStorage("showExitedProcesses") private var showsExited = true
    @State private var order = OrderMemory()
    /// Which columns are shown and in what order; changed from the menu on
    /// the table header and kept between launches.
    @AppStorage("processColumns") private var columns = TableColumnCustomization<Row>()
    @State private var pendingAction: PendingAction?
    @State private var errorMessage: String?

    private let currentUID = getuid()
    private let ownPID = getpid()

    private var visibleProcesses: [ProcessSample] {
        (monitor.tableProcesses + (showsExited ? monitor.exitedProcesses : []))
            .filter { scope == .all || $0.uid == currentUID }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// The list in its two groups: apps with what they started, and the rest.
    private struct Groups {
        var applications: [Row] = []
        var background: [Row] = []
        /// How many apps are running, and how many processes belong to none.
        var applicationCount = 0
        var backgroundCount = 0

        var all: [Row] { applications + background }
    }

    /// Splits the processes into the two groups and puts each in order.
    /// An application is what the Dock would show; everything it started
    /// counts as part of it.
    private func groups(_ processes: [ProcessSample]) -> Groups {
        let apps = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map(\.processIdentifier)
        )
        let owners = owners(of: processes)
        var known: [pid_t: Bool] = [:]
        /// Whether the process is an app or belongs, however indirectly, to one.
        func belongsToApp(_ pid: pid_t) -> Bool {
            if let answer = known[pid] { return answer }
            let answer = apps.contains(pid) || (owners[pid].map { belongsToApp($0) } ?? false)
            known[pid] = answer
            return answer
        }

        var groups = Groups()
        let running = processes.filter { !$0.hasExited }
        groups.applicationCount = running.count { apps.contains($0.pid) }
        groups.backgroundCount = running.count { !belongsToApp($0.pid) }

        if showsTree {
            // A group goes where the process at its top goes.
            for row in treeRows(processes, owners: owners) {
                if apps.contains(row.process.pid) {
                    groups.applications.append(row)
                } else {
                    groups.background.append(row)
                }
            }
        } else {
            let applications = sorted(processes.filter { belongsToApp($0.pid) }.map { Row(id: 0, process: $0) })
            let background = sorted(processes.filter { !belongsToApp($0.pid) }.map { Row(id: 0, process: $0) })
            // Positions run through both groups, so every row has its own.
            groups.applications = applications.enumerated().map { Row(id: $0.offset, process: $0.element.process) }
            groups.background = background.enumerated().map {
                Row(id: applications.count + $0.offset, process: $0.element.process)
            }
        }
        return groups
    }

    // MARK: Ordering

    /// Whether the list is sorted by CPU with smoothing on, and in which direction.
    private var smoothCPUOrder: SortOrder? {
        guard sortsSmoothly, let first = sortOrder.first, first.keyPath == \Row.process.cpu else { return nil }
        return first.order
    }

    /// Sorts siblings by the current sort order. By CPU with smoothing on,
    /// rows are ordered by their averaged CPU and keep their places until
    /// one clearly overtakes another, so the list does not reshuffle on
    /// every refresh.
    private func sorted(_ rows: [Row]) -> [Row] {
        guard let direction = smoothCPUOrder else { return rows.sorted(using: sortOrder) }
        let sign = direction == .reverse ? 1.0 : -1.0
        func key(_ row: Row) -> Double { row.process.smoothedCPU * sign }

        guard !order.ranks.isEmpty else {
            return rows.sorted { (key($0), $1.process.pid) > (key($1), $0.process.pid) }
        }
        // Start from where the rows were; new ones go to the end.
        var settled = rows.sorted {
            (order.ranks[$0.process.pid] ?? .max, $0.process.pid)
                < (order.ranks[$1.process.pid] ?? .max, $1.process.pid)
        }
        // A row moves up past its neighbour only when it leads by a margin:
        // half a percent of a core plus a tenth of the neighbour's own load.
        for index in settled.indices.dropFirst() {
            var position = index
            while position > 0 {
                let above = key(settled[position - 1])
                guard key(settled[position]) > above + 0.5 + abs(above) * 0.1 else { break }
                settled.swapAt(position, position - 1)
                position -= 1
            }
        }
        return settled
    }

    /// Remembers the order just shown, for the next refresh to start from.
    private func remember(_ rows: [Row]) {
        let settings = "\(showsTree)-\(smoothCPUOrder.map { "\($0)" } ?? "plain")"
        var ranks: [pid_t: Int] = [:]
        if smoothCPUOrder != nil {
            func visit(_ rows: [Row]) {
                for row in rows {
                    ranks[row.process.pid] = ranks.count
                    visit(row.children ?? [])
                }
            }
            visit(rows)
        }
        order.ranks = ranks
        order.settings = settings
    }

    /// Ranks made under other sort settings say nothing about this order.
    private func forgetStaleOrder() {
        let settings = "\(showsTree)-\(smoothCPUOrder.map { "\($0)" } ?? "plain")"
        if order.settings != settings { order.ranks = [:] }
    }

    /// The process each one belongs under: the one that started it or, for a
    /// helper that launchd started on an app's behalf, that app. Nearly
    /// everything is started by launchd (pid 1), so its children have no
    /// owner; otherwise the whole list would be one group.
    private func owners(of processes: [ProcessSample]) -> [pid_t: pid_t] {
        let known = Set(processes.map(\.pid))
        var owners: [pid_t: pid_t] = [:]
        for process in processes {
            for candidate in [process.parentPID, process.responsiblePID]
            where candidate > 1 && candidate != process.pid && known.contains(candidate) {
                owners[process.pid] = candidate
                break
            }
        }
        // Mixing the two kinds of link could in theory close a loop, which
        // would hide everything in it. A process whose chain does not end
        // stands on its own.
        for process in processes {
            var current = process.pid
            var steps = 0
            while let next = owners[current], steps <= 64 {
                current = next
                steps += 1
            }
            if steps > 64 { owners[process.pid] = nil }
        }
        return owners
    }

    /// Groups processes under their owners.
    private func treeRows(_ processes: [ProcessSample], owners: [pid_t: pid_t]) -> [Row] {
        var childrenOf: [pid_t: [ProcessSample]] = [:]
        var roots: [ProcessSample] = []
        for process in processes {
            if let owner = owners[process.pid] {
                childrenOf[owner, default: []].append(process)
            } else {
                roots.append(process)
            }
        }

        func row(for process: ProcessSample, depth: Int) -> Row {
            // The depth limit only guards against a malformed parent chain.
            let children = depth < 32
                ? (childrenOf[process.pid] ?? []).map { row(for: $0, depth: depth + 1) }
                : []
            var total = process
            var descendants = children.count
            for child in children {
                total.add(child.process)
                descendants += child.descendantCount
            }
            return Row(
                id: Int(process.pid),
                process: total,
                descendantCount: descendants,
                children: children.isEmpty ? nil : sorted(children)
            )
        }
        return sorted(roots.map { row(for: $0, depth: 0) })
    }

    private func pid(forRow id: Int, in rows: [Row]) -> pid_t? {
        if showsTree { return pid_t(id) }
        return rows.indices.contains(id) ? rows[id].process.pid : nil
    }

    /// Translates between the table's row identities and the selected pid.
    private func rowSelection(in rows: [Row]) -> Binding<Int?> {
        Binding(
            get: {
                guard let selection else { return nil }
                return showsTree ? Int(selection) : rows.first { $0.process.pid == selection }?.id
            },
            set: { id in selection = id.flatMap { pid(forRow: $0, in: rows) } }
        )
    }

    /// The selected process, including one that has just quit and is still listed.
    private var selected: ProcessSample? {
        guard let selection else { return nil }
        return monitor.tableProcesses.first { $0.pid == selection }
            ?? monitor.exitedProcesses.first { $0.pid == selection }
    }

    /// Other users' processes can only be signalled through the root helper.
    private func canSignal(_ process: ProcessSample?) -> Bool {
        guard let process, !process.hasExited, process.pid > 1, process.pid != ownPID else { return false }
        return process.uid == currentUID || helper.isEnabled
    }

    // MARK: Columns

    // The columns are declared in three lots: a table takes at most ten in
    // one list, and the compiler gives up on a single long one.

    @TableColumnBuilder<Row, KeyPathComparator<Row>>
    private var identityColumns: some TableColumnContent<Row, KeyPathComparator<Row>> {
        TableColumn("Name", value: \.process.name) { row in
            let process = row.process
            HStack(spacing: 6) {
                ProcessIcon(path: process.path)
                Text(process.name)
                    .lineLimit(1)
                    .foregroundStyle(process.hasExited ? .red : .primary)
                if process.hasExited {
                    Text("exited")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if row.descendantCount > 0 {
                    // The figures in this row cover the whole group.
                    Text("+\(row.descendantCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Totals include \(row.descendantCount) child processes")
                }
            }
        }
        .width(min: 180, ideal: 260)
        .customizationID("name")
        // A row without its name says nothing.
        .disabledCustomizationBehavior(.visibility)

        TableColumn("PID", value: \.process.pid) { row in
            let process = row.process
            Text(verbatim: String(process.pid))
                .monospacedDigit()
        }
        .width(min: 50, ideal: 70, max: 90)
        .customizationID("pid")

        TableColumn("User", value: \.process.user)
            .width(min: 60, ideal: 110, max: 160)
            .customizationID("user")
    }

    @TableColumnBuilder<Row, KeyPathComparator<Row>>
    private var usageColumns: some TableColumnContent<Row, KeyPathComparator<Row>> {
        TableColumn("CPU", value: \.process.cpu) { row in
            let process = row.process
            Text(process.hasStats ? (process.cpu / 100).percentFormatted : "—")
                .monospacedDigit()
                .foregroundStyle(process.hasStats && !process.hasExited ? .primary : .tertiary)
                .modifier(ChangeHighlight(heat: process.cpuHeat))
        }
        .width(min: 60, ideal: 80, max: 110)
        .customizationID("cpu")

        TableColumn("Memory", value: \.process.memory) { row in
            let process = row.process
            Text(process.hasStats ? process.memory.memoryFormatted : "—")
                .monospacedDigit()
                .foregroundStyle(process.hasStats && !process.hasExited ? .primary : .tertiary)
                .modifier(ChangeHighlight(heat: process.memoryHeat))
        }
        .width(min: 80, ideal: 100, max: 130)
        .customizationID("memory")

        TableColumn("Threads", value: \.process.threads) { row in
            let process = row.process
            Text(process.threads > 0 ? String(process.threads) : "—")
                .monospacedDigit()
                .foregroundStyle(process.threads > 0 ? .primary : .tertiary)
        }
        .width(min: 50, ideal: 64, max: 80)
        .customizationID("threads")

        TableColumn("Disk read", value: \.process.diskRead) { row in
            let process = row.process
            rate(process.diskRead, known: process.hasStats)
        }
        .width(min: 70, ideal: 90, max: 120)
        .customizationID("diskRead")

        TableColumn("Disk write", value: \.process.diskWrite) { row in
            let process = row.process
            rate(process.diskWrite, known: process.hasStats)
        }
        .width(min: 70, ideal: 90, max: 120)
        .customizationID("diskWrite")
    }

    @TableColumnBuilder<Row, KeyPathComparator<Row>>
    private var otherColumns: some TableColumnContent<Row, KeyPathComparator<Row>> {
        TableColumn("Network", value: \.process.network) { row in
            let process = row.process
            rate(process.network, known: true)
        }
        .width(min: 70, ideal: 90, max: 120)
        .customizationID("network")

        TableColumn("Power", value: \.process.power) { row in
            let process = row.process
            Text(process.hasStats ? process.power.smallPowerFormatted : "—")
                .monospacedDigit()
                .foregroundStyle(process.hasStats && process.power >= 0.001 ? .primary : .tertiary)
        }
        .width(min: 60, ideal: 76, max: 100)
        .customizationID("power")

        TableColumn("Status") { row in
            Text(row.process.hasExited ? "Exited" : "Running")
                .foregroundStyle(row.process.hasExited ? .red : .primary)
        }
        .width(min: 60, ideal: 80, max: 110)
        .customizationID("status")
        .defaultVisibility(.hidden)

        TableColumn("Command", value: \.process.path) { row in
            Text(row.process.path.isEmpty ? "—" : row.process.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.process.path.isEmpty ? .tertiary : .primary)
                .help(row.process.path)
        }
        .width(min: 120, ideal: 260)
        .customizationID("command")
        .defaultVisibility(.hidden)
    }

    var body: some View {
        let visible = visibleProcesses
        let _ = forgetStaleOrder()
        let groups = groups(visible)
        let rows = groups.all
        let _ = remember(rows)

        Table(
            of: Row.self, selection: rowSelection(in: rows), sortOrder: $sortOrder,
            columnCustomization: $columns
        ) {
            identityColumns
            usageColumns
            otherColumns
        } rows: {
            Section {
                OutlineGroup(groups.applications, children: \.children) { TableRow($0) }
            } header: {
                groupHeader("Applications (\(groups.applicationCount))")
            }
            Section {
                OutlineGroup(groups.background, children: \.children) { TableRow($0) }
            } header: {
                groupHeader("Background processes (\(groups.backgroundCount))")
            }
        }
        // Row identities mean different things in the two modes (position
        // or pid), so switching builds a fresh table instead of diffing.
        .id(showsTree)
        // Values must not animate from one row's process to another's.
        .transaction { $0.animation = nil }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if let id = ids.first, let pid = pid(forRow: id, in: rows),
               let process = monitor.tableProcesses.first(where: { $0.pid == pid }) {
                Button("Quit…") { request(.quit, for: process) }
                    .disabled(!canSignal(process))
                Button("Force Quit…") { request(.forceQuit, for: process) }
                    .disabled(!canSignal(process))
                Divider()
                Button("Show in Finder") { reveal(process) }
                    .disabled(process.path.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if showsDetails {
                    Divider()
                    ProcessDetails(
                        process: selected,
                        parentName: selected.flatMap { process in
                            monitor.tableProcesses.first { $0.pid == process.parentPID }?.name
                        }
                    )
                }
                if helper.state != .enabled {
                    Divider()
                    HelperStatusView()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
            .background(Dashboard.pageFill)
        }
        // Another tab asked to show a particular process.
        .task(id: navigation.processToReveal) {
            guard let pid = navigation.processToReveal else { return }
            searchText = ""
            scope = .all
            selection = pid
            showsDetails = true
            navigation.processToReveal = nil
        }
        .searchable(text: $searchText, prompt: "Filter by name")
        .navigationTitle("Processes")
        .navigationSubtitle("\(visible.count { !$0.hasExited }) of \(monitor.tableProcesses.count)")
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Menu("Process View", systemImage: "list.bullet.indent") {
                    Toggle("Process Tree", isOn: $showsTree)
                    Toggle("Smooth CPU Sorting", isOn: $sortsSmoothly)
                    Toggle("Show Exited Processes", isOn: $showsExited)
                }
                .help("How the list is grouped and ordered")
            }
            ToolbarItemGroup {
                Button("Quit", systemImage: "xmark.circle") {
                    if let selected { request(.quit, for: selected) }
                }
                .help("Ask the selected process to quit")
                .disabled(!canSignal(selected))

                Button("Force Quit", systemImage: "xmark.octagon") {
                    if let selected { request(.forceQuit, for: selected) }
                }
                .help("Stop the selected process immediately")
                .disabled(!canSignal(selected))
            }
            ToolbarItem {
                Toggle("Info", systemImage: "info.circle", isOn: $showsDetails)
                    .help("Show details of the selected process below the list")
            }
        }
        .confirmationDialog(
            pendingAction.map { title(for: $0) } ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { pending in
            Button(pending.action == .quit ? "Quit" : "Force Quit", role: .destructive) {
                perform(pending)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(
                (pending.action == .quit
                    ? "PID \(String(pending.process.pid)). The process is asked to exit and can finish what it is doing first."
                    : "PID \(String(pending.process.pid)). The process is stopped immediately and unsaved changes are lost.")
                    + (pending.process.uid == currentUID
                        ? ""
                        : " This process belongs to “\(pending.process.user)”; stopping system processes can log you out or freeze the Mac.")
            )
        }
        .alert(
            "Couldn’t stop the process",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.vertical, 3)
    }

    /// A throughput cell; idle values are dimmed so busy rows stand out.
    private func rate(_ value: Double, known: Bool) -> some View {
        Text(known ? value.rateFormatted : "—")
            .monospacedDigit()
            .foregroundStyle(known && value >= 1 ? .primary : .tertiary)
    }

    private func title(for pending: PendingAction) -> String {
        pending.action == .quit
            ? "Quit “\(pending.process.name)”?"
            : "Force quit “\(pending.process.name)”?"
    }

    private func request(_ action: ProcessControl.Action, for process: ProcessSample) {
        pendingAction = PendingAction(action: action, process: process)
    }

    private func perform(_ pending: PendingAction) {
        let process = pending.process
        if process.uid == currentUID {
            do {
                try ProcessControl.send(pending.action, to: process.pid)
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            Task {
                do {
                    try await HelperClient.shared.sendSignal(pending.action.signal, to: process.pid)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func reveal(_ process: ProcessSample) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: process.path)])
    }
}

/// Lights a cell up when its number has just changed and lets it fade over
/// the next refreshes. The fade is in steps with the data, not animated:
/// animating a thousand cells would cost more than everything else here.
private struct ChangeHighlight: ViewModifier {
    let heat: Double

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(heat * 0.42), in: .rect(cornerRadius: 3))
    }
}

/// Facts and figures of the selected process, in a strip under the list.
private struct ProcessDetails: View {
    let process: ProcessSample?
    let parentName: String?

    /// The selected process's command with its arguments, once read.
    @State private var commandLine: String?

    var body: some View {
        Group {
            if let process {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(process.name) (\(String(process.pid)))")
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        CopyableLine(title: "Path", text: process.path)
                        // Where the system keeps the arguments to itself,
                        // the path is all there is of the command.
                        CopyableLine(title: "Command", text: commandLine ?? process.path, isCode: true)
                    }
                    // Arguments are read for the selected process only, when it changes.
                    .task(id: process.pid) {
                        commandLine = ProcessCommandLine.read(pid: process.pid)
                    }
                    HStack(alignment: .top, spacing: 20) {
                        DetailColumn(title: "Identity", rows: [
                            ("Parent", "\(parentName ?? "unknown") (\(String(process.parentPID)))"),
                            ("User", process.user),
                            ("Status", process.hasExited ? "Exited" : "Running"),
                        ])
                        DetailColumn(title: "Lifetime", rows: [
                            ("Started", process.startDate.formatted(date: .abbreviated, time: .shortened)),
                            ("Uptime", uptime(of: process)),
                            ("Threads", process.threads > 0 ? String(process.threads) : unavailable),
                        ])
                        DetailColumn(title: "Processor", rows: [
                            ("CPU", measured(process) { ($0.cpu / 100).percentFormatted }),
                            ("CPU time", measured(process) { $0.cpuTime.cpuTimeFormatted }),
                            ("Power", measured(process) { $0.power.smallPowerFormatted }),
                        ])
                        DetailColumn(title: "Memory", rows: [
                            ("Footprint", measured(process) { $0.memory.memoryFormatted }),
                        ])
                        DetailColumn(title: "Disk", rows: [
                            ("Reading", measured(process) { $0.diskRead.rateFormatted }),
                            ("Writing", measured(process) { $0.diskWrite.rateFormatted }),
                            ("Read", measured(process) { $0.diskReadTotal.storageFormatted }),
                            ("Written", measured(process) { $0.diskWrittenTotal.storageFormatted }),
                        ])
                        DetailColumn(title: "Network", rows: [
                            ("Receiving", process.networkIn.rateFormatted),
                            ("Sending", process.networkOut.rateFormatted),
                        ])
                    }
                }
            } else {
                Text("Select a process to see its details.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private let unavailable = "Unavailable"

    /// Figures of other users' processes are hidden until the helper is installed.
    private func measured(_ process: ProcessSample, _ text: (ProcessSample) -> String) -> String {
        process.hasStats ? text(process) : unavailable
    }

    private func uptime(of process: ProcessSample) -> String {
        Duration.seconds(max(Date().timeIntervalSince(process.startDate), 0))
            .formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
}

/// A labelled line of text with a button that copies it.
private struct CopyableLine: View {
    let title: String
    let text: String
    /// Set for text meant for a terminal, which reads better in a fixed-width face.
    var isCode = false

    @State private var hasCopied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            if text.isEmpty {
                Text("Not disclosed for this process")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(text)
                    .font(isCode ? .callout.monospaced() : .callout)
                    .lineLimit(isCode ? 2 : 1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(text)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    hasCopied = true
                } label: {
                    Label(hasCopied ? "Copied" : "Copy", systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Copy the \(title.lowercased())")
                // The tick goes back to the copy sign after a moment, or at
                // once when the line starts showing something else.
                .task(id: hasCopied) {
                    guard hasCopied else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    hasCopied = false
                }
                .onChange(of: text) { hasCopied = false }
            }
            Spacer(minLength: 0)
        }
    }
}

/// One titled group of facts in the details strip.
private struct DetailColumn: View {
    let title: String
    let rows: [(name: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(rows, id: \.name) { row in
                    GridRow {
                        Text(row.name)
                            .foregroundStyle(.secondary)
                        Text(row.value)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
