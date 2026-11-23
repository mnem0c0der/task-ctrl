import AppKit
import SwiftUI

/// Programs launchd starts at login or boot, with a switch for each.
struct StartupView: View {
    @Environment(StartupItemsModel.self) private var model
    @State private var selection: StartupItem.ID?
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\StartupItem.label)]
    @State private var errorMessage: String?

    private var rows: [StartupItem] {
        model.items
            .filter {
                searchText.isEmpty
                    || $0.label.localizedCaseInsensitiveContains(searchText)
                    || $0.plistPath.localizedCaseInsensitiveContains(searchText)
            }
            .sorted(using: sortOrder)
    }

    private var selected: StartupItem? {
        model.items.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Enabled") { item in
                    Toggle("Start \(item.label) automatically", isOn: enabledBinding(for: item))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .help(
                            item.kind == .daemon
                                ? "Asks for an administrator password; applies from the next restart"
                                : "Applies from the next login"
                        )
                }
                .width(60)

                TableColumn("Name", value: \.label)
                    .width(min: 200, ideal: 300)

                TableColumn("Kind", value: \.kind.rawValue)
                    .width(min: 90, ideal: 110, max: 130)

                TableColumn("Command", value: \.plistPath) { item in
                    Text(item.plistPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
        .searchable(text: $searchText, prompt: "Filter startup apps")
        .navigationTitle("Startup apps")
        .navigationSubtitle("\(rows.count) of \(model.items.count)")
        .toolbar {
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                .help("Read the startup items again")
            }
        }
        .task { await model.load() }
        .onChange(of: selection) {
            if let selected { model.loadPublisher(for: selected) }
        }
        .alert(
            "Couldn’t change the startup item",
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

    private func enabledBinding(for item: StartupItem) -> Binding<Bool> {
        Binding(
            get: { item.isEnabled },
            set: { enabled in
                Task {
                    do {
                        try await model.setEnabled(enabled, for: item)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        )
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let item = selected {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label)
                        .font(.title3.weight(.semibold))
                    Text(item.plistPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(alignment: .top, spacing: 40) {
                    facts("Startup item", [
                        ("Identity", item.label),
                        ("Kind", item.kind.rawValue),
                        ("Publisher", publisher(of: item)),
                        ("Status", item.isEnabled ? "Enabled" : "Disabled"),
                        ("Running", item.pid.map { "Yes (pid \($0))" } ?? "No"),
                        ("Program", item.command.isEmpty ? "Unavailable" : item.command.joined(separator: " ")),
                    ])
                    facts("File", [
                        ("Size", item.fileSize?.storageFormatted ?? "Unavailable"),
                        ("Modified", item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable"),
                        ("Created", item.created?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable"),
                        ("Owner", item.owner ?? "Unavailable"),
                        ("Permissions", item.permissions.map(Self.describe(permissions:)) ?? "Unavailable"),
                    ])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        } else {
            Text("Select a startup item to see its details.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(24)
        }
    }

    private func publisher(of item: StartupItem) -> String {
        guard let executable = item.command.first else { return "Unavailable" }
        return model.publishers[executable] ?? "Checking…"
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
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.callout.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "-rw-r--r-- (644)"
    private static func describe(permissions mode: Int) -> String {
        let letters = Array("rwxrwxrwx")
        let symbolic = (0..<9).map { mode & (1 << (8 - $0)) != 0 ? letters[$0] : "-" }
        return "-" + String(symbolic) + " (" + String(mode & 0o777, radix: 8) + ")"
    }
}
