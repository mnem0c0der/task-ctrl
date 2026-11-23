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
    @State private var showsInspector = false
    @AppStorage("processTree") private var showsTree = false
    @State private var pendingAction: PendingAction?
    @State private var errorMessage: String?

    private let currentUID = getuid()
    private let ownPID = getpid()

    private var visibleProcesses: [ProcessSample] {
        monitor.tableProcesses
            .filter { scope == .all || $0.uid == currentUID }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func flatRows(_ processes: [ProcessSample]) -> [Row] {
        processes
            .map { Row(id: 0, process: $0) }
            .sorted(using: sortOrder)
            .enumerated()
            .map { Row(id: $0.offset, process: $0.element.process) }
    }

    /// Groups processes under the one that started them. Nearly everything is
    /// started by launchd (pid 1), so its children count as top level;
    /// otherwise the whole tree would be one group.
    private func treeRows(_ processes: [ProcessSample]) -> [Row] {
        let known = Set(processes.map(\.pid))
        var childrenOf: [pid_t: [ProcessSample]] = [:]
        var roots: [ProcessSample] = []
        for process in processes {
            let parent = process.parentPID
            if parent > 1, parent != process.pid, known.contains(parent) {
                childrenOf[parent, default: []].append(process)
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
                children: children.isEmpty ? nil : children.sorted(using: sortOrder)
            )
        }
        return roots.map { row(for: $0, depth: 0) }.sorted(using: sortOrder)
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

    private var selected: ProcessSample? {
        guard let selection else { return nil }
        return monitor.tableProcesses.first { $0.pid == selection }
    }

    /// Other users' processes can only be signalled through the root helper.
    private func canSignal(_ process: ProcessSample?) -> Bool {
        guard let process, process.pid > 1, process.pid != ownPID else { return false }
        return process.uid == currentUID || helper.isEnabled
    }

    var body: some View {
        let visible = visibleProcesses
        let rows = showsTree ? treeRows(visible) : flatRows(visible)

        Table(rows, children: \.children, selection: rowSelection(in: rows), sortOrder: $sortOrder) {
            TableColumn("Name", value: \.process.name) { row in
                let process = row.process
                HStack(spacing: 6) {
                    ProcessIcon(path: process.path)
                    Text(process.name)
                        .lineLimit(1)
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

            TableColumn("PID", value: \.process.pid) { row in
                let process = row.process
                Text(verbatim: String(process.pid))
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 70, max: 90)

            TableColumn("User", value: \.process.user)
                .width(min: 60, ideal: 110, max: 160)

            TableColumn("CPU", value: \.process.cpu) { row in
                let process = row.process
                Text(process.hasStats ? (process.cpu / 100).percentFormatted : "—")
                    .monospacedDigit()
                    .foregroundStyle(process.hasStats ? .primary : .tertiary)
            }
            .width(min: 60, ideal: 80, max: 110)

            TableColumn("Memory", value: \.process.memory) { row in
                let process = row.process
                Text(process.hasStats ? process.memory.memoryFormatted : "—")
                    .monospacedDigit()
                    .foregroundStyle(process.hasStats ? .primary : .tertiary)
            }
            .width(min: 80, ideal: 100, max: 130)

            TableColumn("Threads", value: \.process.threads) { row in
                let process = row.process
                Text(process.threads > 0 ? String(process.threads) : "—")
                    .monospacedDigit()
                    .foregroundStyle(process.threads > 0 ? .primary : .tertiary)
            }
            .width(min: 50, ideal: 64, max: 80)

            TableColumn("Disk", value: \.process.disk) { row in
                let process = row.process
                rate(process.disk, known: process.hasStats)
            }
            .width(min: 70, ideal: 90, max: 120)

            TableColumn("Network", value: \.process.network) { row in
                let process = row.process
                rate(process.network, known: true)
            }
            .width(min: 70, ideal: 90, max: 120)

            TableColumn("Power", value: \.process.power) { row in
                let process = row.process
                Text(process.hasStats ? process.power.smallPowerFormatted : "—")
                    .monospacedDigit()
                    .foregroundStyle(process.hasStats && process.power >= 0.001 ? .primary : .tertiary)
            }
            .width(min: 60, ideal: 76, max: 100)
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
            if helper.state != .enabled {
                VStack(spacing: 0) {
                    Divider()
                    HelperStatusView()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .background(.bar)
            }
        }
        // Another tab asked to show a particular process.
        .task(id: navigation.processToReveal) {
            guard let pid = navigation.processToReveal else { return }
            searchText = ""
            scope = .all
            selection = pid
            showsInspector = true
            navigation.processToReveal = nil
        }
        .searchable(text: $searchText, prompt: "Filter by name")
        .navigationTitle("Processes")
        .navigationSubtitle("\(visible.count) of \(monitor.tableProcesses.count)")
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Toggle("Tree", systemImage: "list.bullet.indent", isOn: $showsTree)
                    .help("Group processes under the app that started them")
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
                Toggle("Info", systemImage: "info.circle", isOn: $showsInspector)
                    .help("Show details of the selected process")
            }
        }
        .inspector(isPresented: $showsInspector) {
            ProcessInspector(
                process: selected,
                parentName: selected.flatMap { process in
                    monitor.tableProcesses.first { $0.pid == process.parentPID }?.name
                }
            )
            .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
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

private struct ProcessInspector: View {
    let process: ProcessSample?
    let parentName: String?

    var body: some View {
        if let process {
            Form {
                Section {
                    HStack(spacing: 8) {
                        ProcessIcon(path: process.path)
                        Text(process.name)
                            .font(.headline)
                            .lineLimit(2)
                    }
                }
                Section("Process") {
                    LabeledContent("PID", value: String(process.pid))
                    LabeledContent(
                        "Parent",
                        value: "\(parentName ?? "unknown") (\(String(process.parentPID)))"
                    )
                    LabeledContent("User", value: process.user)
                    LabeledContent(
                        "Started",
                        value: process.startDate.formatted(date: .abbreviated, time: .standard)
                    )
                }
                Section("Usage") {
                    if process.hasStats {
                        LabeledContent("CPU", value: (process.cpu / 100).percentFormatted)
                        LabeledContent("CPU time", value: process.cpuTime.cpuTimeFormatted)
                        LabeledContent("Memory", value: process.memory.memoryFormatted)
                        LabeledContent("Threads", value: process.threads > 0 ? String(process.threads) : "—")
                        LabeledContent("Power", value: process.power.smallPowerFormatted)
                    } else {
                        Text("CPU and memory of other users’ processes are hidden until the helper is installed.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if process.hasStats {
                    Section("Disk") {
                        LabeledContent("Reading", value: process.diskRead.rateFormatted)
                        LabeledContent("Writing", value: process.diskWrite.rateFormatted)
                        LabeledContent("Read in total", value: process.diskReadTotal.storageFormatted)
                        LabeledContent("Written in total", value: process.diskWrittenTotal.storageFormatted)
                    }
                }
                Section("Network") {
                    LabeledContent("Receiving", value: process.networkIn.rateFormatted)
                    LabeledContent("Sending", value: process.networkOut.rateFormatted)
                }
                if !process.path.isEmpty {
                    Section("Path") {
                        Text(process.path)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .monospacedDigit()
        } else {
            ContentUnavailableView(
                "No process selected",
                systemImage: "cursorarrow.click",
                description: Text("Select a row to see its details.")
            )
        }
    }
}
