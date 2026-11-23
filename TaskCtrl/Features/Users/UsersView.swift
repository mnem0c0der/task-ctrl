import SwiftUI

/// Accounts that currently run something, each expandable to its processes.
struct UsersView: View {
    /// A user or one of their processes. Users get negative ids so they can
    /// never collide with a pid.
    private struct Row: Identifiable {
        let id: Int
        let name: String
        let isUser: Bool
        let status: String
        /// Number of processes; zero on process rows.
        let count: Int
        let cpu: Double
        let memory: UInt64
        /// Zero on user rows.
        let pid: pid_t
        let path: String
        let hasStats: Bool
        var children: [Row]?

        static func id(forUser uid: uid_t) -> Int { -Int(uid) - 1 }
    }

    @Environment(SystemMonitor.self) private var monitor
    @State private var selection: Int?
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\Row.name, comparator: .localizedStandard)]
    @State private var accounts: [uid_t: UserAccount] = [:]

    private let cores = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))

    var body: some View {
        let processes = monitor.tableProcesses
        let console = UserAccount.consoleUID
        let rows = userRows(processes, console: console)

        VStack(spacing: 0) {
            Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("User", value: \.name) { row in
                    HStack(spacing: 6) {
                        if row.isUser {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.secondary)
                        } else {
                            ProcessIcon(path: row.path)
                        }
                        Text(row.name)
                            .fontWeight(row.isUser ? .semibold : .regular)
                            .lineLimit(1)
                    }
                }
                .width(min: 220, ideal: 320)

                TableColumn("Status", value: \.status)
                    .width(min: 80, ideal: 110, max: 140)

                TableColumn("Processes", value: \.count) { row in
                    Text(row.isUser ? String(row.count) : "")
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 90, max: 110)

                TableColumn("CPU", value: \.cpu) { row in
                    // A user's total is shown against the whole machine, a
                    // process against one core, like on the Processes tab.
                    LevelCell(
                        text: row.hasStats ? (row.cpu / 100).percentFormatted : "—",
                        fraction: row.cpu / 100 / (row.isUser ? cores : 1),
                        tint: .blue
                    )
                }
                .width(min: 90, ideal: 120, max: 160)

                TableColumn("Memory", value: \.memory) { row in
                    LevelCell(
                        text: row.hasStats ? row.memory.memoryFormatted : "—",
                        fraction: Double(row.memory) / Double(max(monitor.snapshot.memory.total, 1)),
                        tint: .purple
                    )
                }
                .width(min: 100, ideal: 140, max: 180)

                TableColumn("PID", value: \.pid) { row in
                    Text(row.isUser ? "" : String(row.pid))
                        .monospacedDigit()
                }
                .width(min: 50, ideal: 70, max: 90)
            }
            .transaction { $0.animation = nil }

            Divider()
            detail(processes: processes, console: console)
        }
        .searchable(text: $searchText, prompt: "Filter users")
        .navigationTitle("Users")
        .navigationSubtitle("\(rows.count) accounts running processes")
    }

    // MARK: - Rows

    private func account(_ uid: uid_t) -> UserAccount? {
        accounts[uid] ?? UserAccount(uid: uid)
    }

    private func status(of uid: uid_t, console: uid_t?) -> String {
        if uid == console { return "active" }
        return uid >= 500 ? "background" : "system"
    }

    private func userRows(_ processes: [ProcessSample], console: uid_t?) -> [Row] {
        Dictionary(grouping: processes, by: \.uid)
            .compactMap { uid, owned -> Row? in
                let name = owned.first?.user ?? String(uid)
                guard searchText.isEmpty || name.localizedCaseInsensitiveContains(searchText) else {
                    return nil
                }
                let children = owned.map { process in
                    Row(
                        id: Int(process.pid),
                        name: process.name,
                        isUser: false,
                        status: "Running",
                        count: 0,
                        cpu: process.cpu,
                        memory: process.memory,
                        pid: process.pid,
                        path: process.path,
                        hasStats: process.hasStats
                    )
                }
                return Row(
                    id: Row.id(forUser: uid),
                    name: name,
                    isUser: true,
                    status: status(of: uid, console: console),
                    count: owned.count,
                    cpu: owned.reduce(0) { $0 + $1.cpu },
                    memory: owned.reduce(0) { $0 + $1.memory },
                    pid: 0,
                    path: "",
                    hasStats: owned.contains(where: \.hasStats),
                    children: children.sorted(using: sortOrder)
                )
            }
            .sorted(using: sortOrder)
            // People come before service accounts whatever the sort column:
            // otherwise the one account that matters hides among dozens of
            // system ones. Sorting is stable, so each group keeps its order.
            .sorted { rank(ofUserRow: $0, console: console) < rank(ofUserRow: $1, console: console) }
    }

    private func rank(ofUserRow row: Row, console: uid_t?) -> Int {
        let uid = uid_t(-row.id - 1)
        if uid == console { return 0 }
        if uid >= 500 { return 1 }
        return uid == 0 ? 2 : 3
    }

    // MARK: - Detail

    /// The account the selection belongs to: the user row itself, or the
    /// owner of the selected process.
    private func selectedUID(in processes: [ProcessSample]) -> uid_t? {
        guard let selection else { return nil }
        if selection < 0 { return uid_t(-selection - 1) }
        return processes.first { Int($0.pid) == selection }?.uid
    }

    @ViewBuilder
    private func detail(processes: [ProcessSample], console: uid_t?) -> some View {
        if let uid = selectedUID(in: processes) {
            let owned = processes.filter { $0.uid == uid }
            let info = account(uid)
            let name = info?.name ?? owned.first?.user ?? String(uid)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.map { $0.fullName.isEmpty ? $0.name : $0.fullName } ?? name)
                        .font(.title3.weight(.semibold))
                    Text(name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 40) {
                    facts("Account", [
                        ("UID", String(uid)),
                        ("Group", info.map { "\($0.groupName) (\($0.groupID))" } ?? "Unavailable"),
                        ("Home", info?.home ?? "Unavailable"),
                        ("Shell", info?.shell ?? "Unavailable"),
                        ("Administrator", info.map { $0.isAdministrator ? "Yes" : "No" } ?? "Unavailable"),
                    ])
                    facts("Session", [
                        ("State", status(of: uid, console: console)),
                        ("Processes", String(owned.count)),
                        ("CPU", (owned.reduce(0) { $0 + $1.cpu } / 100).percentFormatted),
                        ("Memory", owned.reduce(0) { $0 + $1.memory }.memoryFormatted),
                    ])
                    facts("Top processes", owned
                        .sorted { $0.cpu > $1.cpu }
                        .prefix(4)
                        .map { ("\($0.name) (\($0.pid))", "\(($0.cpu / 100).percentFormatted) · \($0.memory.memoryFormatted)") })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .task(id: uid) {
                if accounts[uid] == nil { accounts[uid] = UserAccount(uid: uid) }
            }
        } else {
            Text("Select a user to see the account and its session.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(24)
        }
    }

    private func facts(_ title: String, _ rows: [(name: String, value: String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(rows, id: \.name) { row in
                    GridRow {
                        Text(row.name)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(row.value)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .font(.callout.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Right-aligned figure over a bar showing how large it is.
private struct LevelCell: View {
    let text: String
    let fraction: Double
    let tint: Color

    var body: some View {
        Text(text)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(alignment: .leading) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(tint.opacity(0.12))
                        Rectangle()
                            .fill(tint.opacity(0.55))
                            .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                    }
                }
            }
    }
}
