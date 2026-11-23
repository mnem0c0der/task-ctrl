import AppKit
import SwiftUI

/// Installed apps with their size and leftovers, and a way to remove them.
struct InstalledAppsView: View {
    @Environment(InstalledAppsModel.self) private var model
    @State private var selection: Set<InstalledApp.ID> = []
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\InstalledApp.name, comparator: .localizedStandard)]
    @State private var pendingUninstall: [InstalledApp] = []
    @State private var isUninstalling = false
    @State private var message: String?

    private var rows: [InstalledApp] {
        model.apps
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
            .sorted(using: sortOrder)
    }

    private var selectedApps: [InstalledApp] {
        model.apps.filter { selection.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 0) {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.id))
                            .resizable()
                            .frame(width: 22, height: 22)
                        Text(app.name)
                            .lineLimit(1)
                        if app.isSystem {
                            Text("macOS")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: .capsule)
                        }
                    }
                    .padding(.vertical, 2)
                }

                TableColumn("Size", value: \.sizeSortKey) { app in
                    Text(app.size?.storageFormatted ?? "…")
                        .monospacedDigit()
                        .foregroundStyle(app.size == nil ? .tertiary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 80, ideal: 100, max: 120)
            }
            .overlay {
                if model.isLoading, model.apps.isEmpty {
                    ProgressView()
                } else if rows.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .frame(minWidth: 320, idealWidth: 420)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.black)
        .searchable(text: $searchText, prompt: "Filter apps")
        .navigationTitle("Installed Apps")
        .navigationSubtitle("\(rows.count) of \(model.apps.count)")
        .toolbar {
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                .help("Look for apps again")
            }
        }
        .task {
            if model.apps.isEmpty { await model.load() }
        }
        .onChange(of: selection) {
            for app in selectedApps { model.loadDetails(for: app) }
        }
        .confirmationDialog(
            uninstallTitle,
            isPresented: Binding(
                get: { !pendingUninstall.isEmpty },
                set: { if !$0 { pendingUninstall = [] } }
            )
        ) {
            Button("Move to Trash", role: .destructive) { uninstall(pendingUninstall) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(uninstallSummary)
        }
        .alert(
            "Couldn’t uninstall",
            isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        let apps = selectedApps
        if apps.count == 1, let app = apps.first {
            single(app)
        } else if apps.count > 1 {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(apps.count) apps selected")
                    .font(.title2.weight(.semibold))
                Text(apps.map(\.name).joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                uninstallButton(apps)
            }
            .padding(24)
        } else {
            Text("Select an app to see its details and related files.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func single(_ app: InstalledApp) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.id))
                        .resizable()
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(app.name)
                                .font(.title.weight(.semibold))
                            if let version = app.version {
                                Text(version)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                            fact("Editor", model.publishers[app.id] ?? "Checking…")
                            fact("Opened", app.lastOpened?.formatted(date: .long, time: .shortened) ?? "Unknown")
                            fact("Modified", app.modified?.formatted(date: .long, time: .shortened) ?? "Unknown")
                            fact("Location", app.url.deletingLastPathComponent().path(percentEncoded: false))
                        }
                        .font(.callout)
                    }
                    Spacer(minLength: 8)
                    uninstallButton([app])
                }

                Divider()
                relatedFiles(of: app)
            }
            .padding(24)
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func relatedFiles(of app: InstalledApp) -> some View {
        if let files = model.relatedFiles[app.id] {
            let total = files.compactMap(\.size).reduce(0, +)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Related Files (\(files.count))")
                    .font(.title3.weight(.semibold))
                Text(files.isEmpty ? "—" : total.storageFormatted)
                    .foregroundStyle(.secondary)
            }
            if files.isEmpty {
                Text("No files were found outside the application bundle.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(files) { file in
                        HStack(spacing: 12) {
                            Text(file.url.path(percentEncoded: false))
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Text(file.size?.storageFormatted ?? "size not read")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Button("Show in Finder", systemImage: "magnifyingglass") {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        } else {
            ProgressView("Looking for related files…")
        }
    }

    // MARK: - Uninstall

    private func uninstallButton(_ apps: [InstalledApp]) -> some View {
        let blocker = apps.lazy.compactMap { model.blocker(for: $0) }.first
        return Button("Uninstall…") { pendingUninstall = apps }
            .disabled(blocker != nil || isUninstalling)
            .help(blocker ?? "Move the app and its related files to the Trash")
    }

    private var uninstallTitle: String {
        pendingUninstall.count == 1
            ? "Uninstall “\(pendingUninstall.first?.name ?? "")”?"
            : "Uninstall \(pendingUninstall.count) apps?"
    }

    private var uninstallSummary: String {
        let leftovers = pendingUninstall.flatMap { model.relatedFiles[$0.id] ?? [] }
        let size = pendingUninstall.compactMap(\.size).reduce(0, +) + leftovers.compactMap(\.size).reduce(0, +)
        var text = pendingUninstall.count == 1 ? "The app" : "The apps"
        if !leftovers.isEmpty { text += " and \(leftovers.count) related files or folders" }
        text += " (\(size.storageFormatted)) will be moved to the Trash. You can put them back until you empty it."
        return text
    }

    private func uninstall(_ apps: [InstalledApp]) {
        // Something may have been launched since the button was enabled.
        if let blocker = apps.lazy.compactMap({ model.blocker(for: $0) }).first {
            message = blocker
            return
        }
        isUninstalling = true
        Task {
            do {
                try await model.uninstall(apps)
                selection = []
            } catch {
                message = error.localizedDescription
            }
            isUninstalling = false
        }
    }
}
