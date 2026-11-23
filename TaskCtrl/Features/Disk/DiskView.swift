import AppKit
import SwiftUI

struct Volume: Identifiable {
    let url: URL
    let name: String
    let total: UInt64
    let available: UInt64

    var id: URL { url }
    var used: UInt64 { total > available ? total - available : 0 }

    static func mounted() -> [Volume] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  let total = values.volumeTotalCapacity, total > 0
            else { return nil }
            return Volume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                total: UInt64(total),
                available: UInt64(max(values.volumeAvailableCapacityForImportantUsage ?? 0, 0))
            )
        }
    }
}

/// Disk map on the left; capacity, file types, largest folders and scan
/// history on the right.
struct DiskView: View {
    enum Presentation: String, CaseIterable, Identifiable {
        case balls = "Balls"
        case list = "List"

        var id: Self { self }
    }

    @Environment(DiskScanModel.self) private var model
    @AppStorage("diskPresentation") private var presentation: Presentation = .balls
    @State private var volumes: [Volume] = []
    @State private var isChoosingFolder = false
    @State private var showsLargestFiles = false

    /// The volume the scan target lives on.
    private var volume: Volume? {
        let target = model.target.path(percentEncoded: false)
        return volumes
            .filter { target.hasPrefix($0.url.path(percentEncoded: false)) }
            .max { $0.url.path.count < $1.url.path.count }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                map
                Divider()
                progress
                Divider()
                largestFiles
            }
            Divider()
            sidebar
                .frame(width: 300)
        }
        .background(Dashboard.pageFill)
        .navigationTitle("Disk Space")
        .task { volumes = Volume.mounted() }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.target = url }
        }
    }

    // MARK: - Left side

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button(model.target.lastPathComponent.isEmpty ? "/" : model.target.lastPathComponent) {
                isChoosingFolder = true
            }
            .help("Choose the folder to scan")
            .disabled(model.phase == .scanning)

            Picker("View", selection: $presentation) {
                ForEach(Presentation.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            breadcrumb
            Spacer(minLength: 8)

            if model.phase == .scanning {
                Button("Cancel") { model.cancel() }
            } else {
                Button(model.root == nil ? "Scan" : "Rescan") { model.scan() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// Path from the scan root to the folder shown; click a part to go back up.
    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.path.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(index == 0 ? "/" + node.url.lastPathComponent : node.name) {
                        model.pop(to: index)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == model.path.count - 1 ? .primary : .secondary)
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private var map: some View {
        switch model.phase {
        case .idle:
            ContentUnavailableView(
                "Nothing scanned yet",
                systemImage: "circle.hexagongrid",
                description: Text("Scan the folder to see what takes up space. Nothing is deleted without asking you.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ContentUnavailableView("Scan failed", systemImage: "exclamationmark.triangle", description: Text(message))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .finished:
            if presentation == .list {
                DiskAnalyzerView(onDiskChanged: { volumes = Volume.mounted() }, showsHeader: false)
            } else if let folder = model.current {
                DiskBubblesView(folder: folder) { model.open($0) }
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 12) {
            SegmentMeter(fraction: scanFraction, tint: .green, segments: 28, axis: .horizontal)
                .frame(height: 16)
            Text(scanStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// There is no telling in advance how much a folder holds, so progress is
    /// measured against the space in use on its volume: exact for a whole
    /// disk, an underestimate for a single folder.
    private var scanFraction: Double {
        switch model.phase {
        case .finished:
            return 1
        case .scanning:
            guard let used = volume?.used, used > 0 else { return 0 }
            return min(Double(model.progress.bytes) / Double(used), 0.97)
        default:
            return 0
        }
    }

    private var scanStatus: String {
        switch model.phase {
        case .idle: "Not scanned"
        case .scanning: "Scanning…"
        case .failed: "Failed"
        case .finished:
            "Complete · \(model.entryCount.formatted()) items"
                + (model.unreadableCount > 0 ? " · \(model.unreadableCount.formatted()) unreadable" : "")
        }
    }

    private var largestFiles: some View {
        DisclosureGroup(isExpanded: $showsLargestFiles) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.largestFiles) { file in
                        HStack(spacing: 10) {
                            Circle().fill(file.category.color).frame(width: 9, height: 9)
                            Text((file.path as NSString).lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text((file.path as NSString).deletingLastPathComponent)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 8)
                            Text(file.size.storageFormatted)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Button("Show in Finder", systemImage: "magnifyingglass") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: file.path)])
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                        .font(.callout)
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(height: 180)
        } label: {
            HStack {
                Text("Largest Files")
                    .font(.headline)
                Spacer()
                Text("\(model.largestFiles.count) tracked")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Right side

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let volume {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(volume.name)
                                .font(.title3.weight(.semibold))
                            Spacer()
                            Text(volume.total.storageFormatted)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(volume.used), total: Double(max(volume.total, 1)))
                            .tint(.gray)
                        HStack {
                            Text("\(volume.used.storageFormatted) used")
                            Spacer()
                            Text("\(volume.available.storageFormatted) free")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    Divider()
                }

                section("File Type") {
                    ForEach(FileCategory.allCases) { category in
                        HStack(spacing: 10) {
                            Circle().fill(category.color).frame(width: 12, height: 12)
                            Text(category.title)
                            Spacer()
                            Text(size(of: category))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()

                section("Largest Folders") {
                    let folders = (model.current?.children ?? []).filter(\.isDirectory).prefix(6)
                    if folders.isEmpty {
                        Text(model.root == nil ? "Scan to find out." : "No subfolders here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(folders)) { folder in
                        Button {
                            model.open(folder)
                        } label: {
                            HStack {
                                Text(folder.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(folder.size.storageFormatted)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Divider()

                section("History") {
                    if model.history.isEmpty {
                        Text("No scans yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.history) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text((record.path as NSString).lastPathComponent.isEmpty
                                    ? "/" : (record.path as NSString).lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(record.size.storageFormatted)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Text(record.date.formatted(date: .long, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private func size(of category: FileCategory) -> String {
        let index = Int(category.rawValue)
        return model.categorySizes.indices.contains(index) ? model.categorySizes[index].storageFormatted : "—"
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            content()
        }
    }
}
