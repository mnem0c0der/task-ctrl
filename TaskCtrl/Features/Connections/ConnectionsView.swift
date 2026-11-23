import SwiftUI

/// Open sockets: who is listening, who is connected where.
struct ConnectionsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case connected = "Connected"
        case listening = "Listening"
        case `public` = "Public"
        case udp = "UDP"
        case ipc = "Local IPC"

        var id: Self { self }

        func includes(_ connection: Connection) -> Bool {
            switch self {
            // Network sockets only; the hundreds of local ones have their own filter.
            case .all: !connection.isIPC
            case .connected: connection.isConnected
            case .listening: connection.isListening
            case .public: connection.isPublic
            case .udp: connection.transport == "UDP"
            case .ipc: connection.isIPC
            }
        }
    }

    @Environment(ConnectionsModel.self) private var model
    @Environment(SystemMonitor.self) private var monitor
    @State private var filter: Filter = .all
    @State private var selection: Connection.ID?
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\Connection.command, comparator: .localizedStandard)]

    private let currentUID = getuid()

    private var rows: [Connection] {
        model.connections
            .filter(filter.includes)
            .filter {
                searchText.isEmpty
                    || $0.command.localizedCaseInsensitiveContains(searchText)
                    || $0.local.localizedCaseInsensitiveContains(searchText)
                    || ($0.remote ?? "").localizedCaseInsensitiveContains(searchText)
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        let rows = rows
        let network = model.connections.filter { !$0.isIPC }

        VStack(spacing: 14) {
            HStack(spacing: 12) {
                CountTile(title: "Connections", symbol: "point.3.connected.trianglepath.dotted",
                          count: network.count, caption: "Open network sockets", tint: .blue)
                CountTile(title: "Listening", symbol: "dot.radiowaves.left.and.right",
                          count: network.count { $0.isListening }, caption: "Open TCP ports", tint: .green)
                CountTile(title: "Public", symbol: "exclamationmark.shield",
                          count: network.count { $0.isPublic }, caption: "All-interface or public address", tint: .orange)
                CountTile(title: "Processes", symbol: "app.connected.to.app.below.fill",
                          count: Set(network.map(\.pid)).count, caption: "With open sockets", tint: .purple)
                TrafficTile(activity: monitor.snapshot.activity, history: monitor.history)
            }
            .frame(height: 104)

            HStack(spacing: 12) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text("\(rows.count) shown of \(model.connections.count)")
                    .foregroundStyle(.secondary)
                Label(
                    model.coversAllUsers ? "All users" : "Current-user visibility",
                    systemImage: model.coversAllUsers ? "person.3" : "person.badge.key"
                )
                .foregroundStyle(.secondary)
                .help(
                    model.coversAllUsers
                        ? "Read through the helper, so system processes are included"
                        : "Sockets of other users' processes are not listed; install the helper to see them"
                )
                Spacer()
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .labelStyle(.iconOnly)
                .help("Read the sockets again now")
            }
            .font(.callout)

            HStack(alignment: .top, spacing: 12) {
                table(rows)
                detail
                    .frame(width: 260)
            }
        }
        .padding(16)
        .background(Color.black)
        .searchable(text: $searchText, prompt: "Filter connections")
        .navigationTitle("Connections")
        // Reading sockets costs a little, so it runs only while this tab shows.
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Table

    private func table(_ rows: [Connection]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Application", value: \.command) { connection in
                HStack(spacing: 8) {
                    Image(systemName: symbol(for: connection))
                        .foregroundStyle(tint(for: connection))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(connection.command)
                            .lineLimit(1)
                        Text("PID \(String(connection.pid)) · \(owner(of: connection))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .width(min: 150, ideal: 170)

            TableColumn("Protocol", value: \.transport) { connection in
                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.isIPC ? "Unix" : connection.transport)
                    Text(connection.isIPC ? "local" : connection.family.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 50, ideal: 56, max: 80)

            TableColumn("State", value: \.state) { connection in
                Text(connection.state)
                    .font(.callout.monospaced())
                    .foregroundStyle(connection.isListening ? .green : .primary)
            }
            .width(min: 80, ideal: 100, max: 130)

            TableColumn("Local endpoint", value: \.local) { connection in
                Text(connection.local)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 110, ideal: 140)

            TableColumn("Remote endpoint") { connection in
                Text(connection.remote ?? "—")
                    .font(.callout.monospaced())
                    .foregroundStyle(connection.remote == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 110, ideal: 140)
        }
        .overlay {
            if !model.hasLoaded {
                ProgressView()
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No connections",
                    systemImage: "network.slash",
                    description: Text("Nothing matches this filter right now.")
                )
            }
        }
        .clipShape(.rect(cornerRadius: 10))
    }

    private func owner(of connection: Connection) -> String {
        connection.uid == currentUID ? "you" : connection.user
    }

    private func symbol(for connection: Connection) -> String {
        if connection.isListening { return "dot.radiowaves.left.and.right" }
        return connection.isIPC ? "arrow.left.arrow.right.square" : "square"
    }

    private func tint(for connection: Connection) -> Color {
        if connection.isPublic { return .orange }
        if connection.isIPC { return .secondary }
        return connection.isConnected ? .blue : .green
    }

    // MARK: - Detail

    private var detail: some View {
        Panel(tint: .white) {
            if let connection = model.connections.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            ProcessIcon(path: monitor.tableProcesses.first { $0.pid == connection.pid }?.path ?? "")
                                .scaleEffect(2)
                                .frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(connection.command)
                                    .font(.title3.weight(.semibold))
                                    .lineLimit(2)
                                Text("PID \(String(connection.pid)) · \(owner(of: connection))")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        section("Connection", [
                            ("Protocol", connection.isIPC
                                ? "Unix domain socket"
                                : "\(connection.transport) · \(connection.family.rawValue)"),
                            ("State", connection.state),
                            ("Service", connection.service ?? "Unknown"),
                            ("Exposure", connection.exposure),
                        ])
                        section("Endpoints", [
                            ("Local", connection.local),
                            ("Remote", connection.remote ?? "None"),
                        ])
                        section("Socket", [
                            ("Descriptor", connection.descriptor),
                            ("Observed", observed(connection)),
                        ])
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Select a connection to see its details.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func observed(_ connection: Connection) -> String {
        guard let since = model.firstSeen[connection.id] else { return "Just now" }
        let seconds = Int(Date().timeIntervalSince(since))
        if seconds < 60 { return "\(max(seconds, 0)) s" }
        return seconds < 3600 ? "\(seconds / 60) min" : "\(seconds / 3600) h \(seconds / 60 % 60) min"
    }

    private func section(_ title: String, _ rows: [(name: String, value: String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.name) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(row.value)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Tiles

private struct CountTile: View {
    let title: String
    let symbol: String
    let count: Int
    let caption: String
    let tint: Color

    var body: some View {
        Panel(tint: tint) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Text(String(count))
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct TrafficTile: View {
    let activity: ActivityReadings
    let history: [HistoryPoint]

    var body: some View {
        Panel(tint: .cyan) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("System traffic", systemImage: "waveform.path.ecg")
                        .font(.callout.weight(.semibold))
                    Spacer()
                }
                Sparkline(
                    points: history,
                    series: [
                        ChartSeries(name: "Received", tint: .cyan) { $0.networkIn },
                        ChartSeries(name: "Sent", tint: .purple) { $0.networkOut },
                    ],
                    domain: 0...history.ceiling(floor: 50_000) { max($0.networkIn, $0.networkOut) }
                )
                HStack(spacing: 12) {
                    Text("↓ \(activity.networkIn.rateFormatted)").foregroundStyle(.cyan)
                    Text("↑ \(activity.networkOut.rateFormatted)").foregroundStyle(.purple)
                }
                .font(.caption.monospacedDigit())
            }
        }
        .frame(minWidth: 230)
    }
}
