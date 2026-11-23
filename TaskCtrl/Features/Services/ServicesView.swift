import AppKit
import SwiftUI

/// Every background service launchd knows from a property list, and whether it runs.
struct ServicesView: View {
    @Environment(ServicesModel.self) private var model
    @Environment(AppNavigation.self) private var navigation
    @State private var selection: ServiceItem.ID?
    @State private var searchText = ""
    @State private var busy: ServiceItem.ID?
    @State private var pendingAction: PendingAction?
    @State private var errorMessage: String?
    // Third-party services first, then the system's, each by name.
    @State private var sortOrder = [
        KeyPathComparator(\ServiceItem.rank),
        KeyPathComparator(\ServiceItem.label, comparator: .localizedStandard),
    ]

    private var rows: [ServiceItem] {
        model.items
            .filter {
                searchText.isEmpty
                    || $0.label.localizedCaseInsensitiveContains(searchText)
                    || $0.program.localizedCaseInsensitiveContains(searchText)
            }
            .sorted(using: sortOrder)
    }

    private struct PendingAction: Identifiable {
        let action: ServiceAction
        let service: ServiceItem

        var id: String { "\(action.rawValue)-\(service.id)" }
    }

    /// Stopping or restarting Apple's own services can break the session,
    /// so those ask first. System services then also ask for a password.
    private func request(_ action: ServiceAction, for service: ServiceItem) {
        if action != .start, service.label.hasPrefix("com.apple.") {
            pendingAction = PendingAction(action: action, service: service)
        } else {
            apply(action, to: service)
        }
    }

    private func apply(_ action: ServiceAction, to service: ServiceItem) {
        busy = service.id
        Task {
            do {
                try await model.perform(action, for: service)
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = nil
        }
    }

    private func searchOnline(_ service: ServiceItem) {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: "\(service.label) macOS")]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }

    private func copyName(_ service: ServiceItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(service.label, forType: .string)
    }

    private var selected: ServiceItem? {
        model.items.first { $0.id == selection }
    }

    var body: some View {
        let rows = rows

        VStack(spacing: 0) {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Running", value: \.runningSortKey) { service in
                    // An indicator; the actions are in the row's context menu.
                    if busy == service.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: service.isRunning ? "checkmark.square.fill" : "square")
                            .foregroundStyle(
                                service.isRunning ? Color.accentColor : Color.secondary.opacity(0.5)
                            )
                            .accessibilityLabel(service.isRunning ? "Running" : "Not running")
                            .help("Right-click the row to start, stop or restart")
                    }
                }
                .width(64)

                TableColumn("Name", value: \.label) { service in
                    Text(service.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 180, ideal: 260)

                TableColumn("Description", value: \.program) { service in
                    Text(service.program)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 180, ideal: 300)

                TableColumn("Group", value: \.group) { service in
                    Text(service.group)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 120, ideal: 170, max: 280)
            }
            .contextMenu(forSelectionType: ServiceItem.ID.self) { ids in
                if let service = model.items.first(where: { $0.id == ids.first }) {
                    Button("Start") { request(.start, for: service) }
                        .disabled(service.isRunning)
                    Button("Stop") { request(.stop, for: service) }
                        .disabled(!service.isLoaded && !service.isRunning)
                    Button("Restart") { request(.restart, for: service) }
                        .disabled(!service.isRunning)
                    Divider()
                    Button("Go to details") {
                        if let pid = service.pid { navigation.revealProcess(pid) }
                    }
                    .disabled(!service.isRunning)
                    Button("Search online") { searchOnline(service) }
                    Button("Copy service name") { copyName(service) }
                }
            }
            .overlay {
                if model.isLoading, model.items.isEmpty {
                    ProgressView()
                } else if rows.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }

            Divider()
            detail
        }
        .searchable(text: $searchText, prompt: "Filter services")
        .navigationTitle("Services")
        .navigationSubtitle(
            "\(rows.count) of \(model.items.count) · \(model.items.count { $0.isRunning }) running"
        )
        .toolbar {
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                .help("Read the services again")
            }
        }
        .task { await model.load() }
        .confirmationDialog(
            "\(pendingAction?.action == .restart ? "Restart" : "Stop") “\(pendingAction?.service.label ?? "")”?",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { pending in
            Button(pending.action == .restart ? "Restart Service" : "Stop Service", role: .destructive) {
                apply(pending.action, to: pending.service)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This is part of macOS. Interrupting it can log you out, break features or freeze the Mac until you restart.")
        }
        .alert(
            "Couldn’t change the service",
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

    @ViewBuilder
    private var detail: some View {
        if let service = selected {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.label)
                        .font(.title3.weight(.semibold))
                    Text(service.command.isEmpty ? "No program recorded" : service.command.joined(separator: " "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack(alignment: .top, spacing: 40) {
                    facts("Service", [
                        ("State", service.state),
                        ("Kind", service.kind),
                        ("Domain", service.domain),
                        ("Group", service.group),
                    ])
                    facts("Registration", [
                        ("Label", service.label),
                        ("Property list", service.plistPath),
                    ])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        } else {
            Text("Select a service to see its details.")
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
                        Text(row.value)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.callout.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension ServiceItem {
    /// Sorts running services first when the column is sorted ascending.
    var runningSortKey: Int { isRunning ? 0 : 1 }
}
