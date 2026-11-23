import AppKit
import SwiftUI

/// Scan controls plus the drill-down list of what takes up space.
struct DiskAnalyzerView: View {
    @Environment(DiskScanModel.self) private var model
    @State private var isChoosingFolder = false
    @State private var pendingTrash: DiskNode?
    @State private var trashError: String?

    /// Called after something was moved to the Trash, so free space can be refreshed.
    var onDiskChanged: () -> Void = {}
    /// False when the surrounding screen provides its own scan controls.
    var showsHeader = true

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.target = url }
        }
        .confirmationDialog(
            "Move “\(pendingTrash?.name ?? "")” to the Trash?",
            isPresented: Binding(
                get: { pendingTrash != nil },
                set: { if !$0 { pendingTrash = nil } }
            ),
            presenting: pendingTrash
        ) { node in
            Button("Move to Trash", role: .destructive) { trash(node) }
            Button("Cancel", role: .cancel) {}
        } message: { node in
            Text("\(node.size.storageFormatted) at \(node.url.path(percentEncoded: false)). You can put it back from the Trash until you empty it.")
        }
        .alert(
            "Couldn’t move to the Trash",
            isPresented: Binding(
                get: { trashError != nil },
                set: { if !$0 { trashError = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(trashError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Disk analysis")
                    .font(.headline)
                Text(model.target.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Choose Folder…") { isChoosingFolder = true }
                .disabled(model.phase == .scanning)
            if model.phase == .scanning {
                Button("Cancel") { model.cancel() }
            } else {
                Button(model.root == nil ? "Scan" : "Rescan") { model.scan() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            ContentUnavailableView(
                "Nothing scanned yet",
                systemImage: "chart.pie",
                description: Text("Scan the folder to see what takes up space. Nothing is deleted without asking you.")
            )
        case .scanning:
            VStack(spacing: 12) {
                ProgressView()
                Text("\(model.progress.entries.formatted()) items · \(model.progress.bytes.storageFormatted)")
                    .font(.callout.monospacedDigit())
                Text(model.progress.currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView(
                "Scan failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .finished:
            if let current = model.current {
                results(for: current)
            }
        }
    }

    private func results(for folder: DiskNode) -> some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            List {
                ForEach(folder.children) { node in
                    DiskRow(
                        name: node.name,
                        symbol: node.isDirectory ? "folder.fill" : "doc",
                        size: node.size,
                        fraction: fraction(node.size, of: folder.size),
                        showsChevron: node.isDirectory
                    )
                    .contentShape(.rect)
                    .onTapGesture { model.open(node) }
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([node.url])
                        }
                        Divider()
                        Button("Move to Trash…", role: .destructive) { pendingTrash = node }
                    }
                }
                if folder.smallFilesCount > 0 {
                    DiskRow(
                        name: folder.smallFilesCount == 1
                            ? "1 smaller file"
                            : "\(folder.smallFilesCount.formatted()) smaller files",
                        symbol: "doc.on.doc",
                        size: folder.smallFilesSize,
                        fraction: fraction(folder.smallFilesSize, of: folder.size),
                        showsChevron: false
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            if model.unreadableCount > 0 {
                Divider()
                unreadableNotice
            }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.path.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button(index == 0 ? node.url.lastPathComponent : node.name) {
                            model.pop(to: index)
                        }
                        .buttonStyle(.plain)
                        .fontWeight(index == model.path.count - 1 ? .semibold : .regular)
                    }
                }
            }
            Spacer()
            if let current = model.current {
                Text(current.size.storageFormatted)
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var unreadableNotice: some View {
        HStack {
            Label(
                "\(model.unreadableCount.formatted()) items couldn’t be read, so totals are incomplete.",
                systemImage: "lock"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Open Full Disk Access Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func trash(_ node: DiskNode) {
        do {
            try model.moveToTrash(node)
            onDiskChanged()
        } catch {
            trashError = error.localizedDescription
        }
    }

    private func fraction(_ part: UInt64, of whole: UInt64) -> Double {
        whole == 0 ? 0 : min(Double(part) / Double(whole), 1)
    }
}

private struct DiskRow: View {
    let name: String
    let symbol: String
    let size: UInt64
    let fraction: Double
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            ProgressView(value: fraction)
                .frame(width: 120)
            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(size.storageFormatted)
                .frame(width: 84, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .opacity(showsChevron ? 1 : 0)
        }
        .font(.callout.monospacedDigit())
        .padding(.vertical, 2)
    }
}
