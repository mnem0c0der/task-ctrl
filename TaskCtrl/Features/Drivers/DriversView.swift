import AppKit
import SwiftUI

/// Kernel and system extensions: what is installed and what is loaded.
struct DriversView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case loaded = "Loaded"
        case notLoaded = "Not loaded"
        case thirdParty = "Third-party"
        case extensions = "Extensions"

        var id: Self { self }

        func includes(_ driver: Driver) -> Bool {
            switch self {
            case .all: true
            case .loaded: driver.isLoaded
            case .notLoaded: !driver.isLoaded
            case .thirdParty: !driver.isApple
            case .extensions: driver.kind == .systemExtension
            }
        }
    }

    @Environment(DriversModel.self) private var model
    @State private var filter: Filter = .all
    @State private var selection: Driver.ID?
    @State private var searchText = ""
    @State private var sortOrder = [
        KeyPathComparator(\Driver.stateSortKey),
        KeyPathComparator(\Driver.name, comparator: .localizedStandard),
    ]

    private var rows: [Driver] {
        model.drivers
            .filter(filter.includes)
            .filter {
                searchText.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.bundleID.localizedCaseInsensitiveContains(searchText)
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        let rows = rows
        let loaded = model.drivers.filter(\.isLoaded)

        VStack(spacing: 14) {
            HStack(spacing: 12) {
                tile("Drivers", "shippingbox", String(model.drivers.count), "Installed on this Mac", .blue)
                tile("Loaded", "bolt.fill", String(loaded.count), "Active right now", .green)
                tile("Third-party", "person.badge.shield.checkmark",
                     String(model.drivers.count { !$0.isApple }), "Not shipped by Apple", .orange)
                tile("Wired memory", "memorychip",
                     loaded.compactMap(\.wiredSize).reduce(0, +).memoryFormatted, "Kernel memory held", .purple)
            }
            .frame(height: 96)

            HStack(spacing: 12) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text("\(rows.count) shown")
                    .foregroundStyle(.secondary)
                Spacer()
                if let updated = model.updated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                        .foregroundStyle(.secondary)
                }
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                .labelStyle(.iconOnly)
                .help("Read the drivers again")
            }
            .font(.callout)

            HStack(alignment: .top, spacing: 12) {
                table(rows)
                detail
                    .frame(width: 320)
            }
        }
        .padding(16)
        .background(Dashboard.pageFill)
        .searchable(text: $searchText, prompt: "Filter drivers")
        .navigationTitle("Drivers")
        .task {
            if model.drivers.isEmpty { await model.load() }
        }
    }

    private func tile(_ title: String, _ symbol: String, _ value: String, _ caption: String, _ tint: Color) -> some View {
        Panel(tint: tint) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Table

    private func table(_ rows: [Driver]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Driver", value: \.name) { driver in
                HStack(spacing: 8) {
                    Image(systemName: driver.kind == .systemExtension ? "puzzlepiece.extension" : "cpu")
                        .foregroundStyle(driver.isLoaded ? .green : .secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(driver.name)
                            .lineLimit(1)
                        Text(driver.bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 2)
            }
            .width(min: 180, ideal: 220)

            TableColumn("State", value: \.stateSortKey) { driver in
                Text(driver.isLoaded ? "Loaded" : "Not loaded")
                    .foregroundStyle(driver.isLoaded ? .green : .secondary)
            }
            .width(min: 70, ideal: 84, max: 100)

            TableColumn("Version", value: \.version) { driver in
                Text(driver.version)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 80, max: 130)

            TableColumn("Wired", value: \.wiredSortKey) { driver in
                Text(driver.wiredSize?.memoryFormatted ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(driver.wiredSize == nil ? .tertiary : .primary)
            }
            .width(min: 60, ideal: 70, max: 100)

            TableColumn("Vendor", value: \.vendor) { driver in
                Text(driver.vendor)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 80, max: 160)
        }
        .overlay {
            if model.isLoading, model.drivers.isEmpty {
                ProgressView()
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No drivers",
                    systemImage: "cpu",
                    description: Text("Nothing matches this filter.")
                )
            }
        }
        .clipShape(.rect(cornerRadius: 10))
    }

    // MARK: - Detail

    private var detail: some View {
        Panel(tint: .white) {
            if let driver = model.drivers.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: driver.kind == .systemExtension ? "puzzlepiece.extension" : "cpu")
                                .font(.system(size: 32))
                                .foregroundStyle(driver.isLoaded ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(driver.name)
                                    .font(.title3.weight(.semibold))
                                Text(driver.bundleID)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Label(
                                    driver.isLoaded ? "Loaded" : "Not loaded",
                                    systemImage: driver.isLoaded ? "checkmark.circle" : "circle"
                                )
                                .font(.callout)
                                .foregroundStyle(driver.isLoaded ? .green : .secondary)
                            }
                        }
                        Divider()
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
                            ForEach(facts(of: driver), id: \.name) { fact in
                                GridRow {
                                    Text(fact.name)
                                        .foregroundStyle(.secondary)
                                    Text(fact.value)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .font(.callout.monospacedDigit())

                        if let note = note(for: driver) {
                            Label(note, systemImage: "lock.fill")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(10)
                                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                        }

                        HStack {
                            Button("Reveal in Finder") {
                                if let path = driver.path {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                                }
                            }
                            .disabled(driver.path == nil)
                            Button("Copy Details") {
                                let text = (["\(driver.name) (\(driver.bundleID))"]
                                    + facts(of: driver).map { "\($0.name): \($0.value)" })
                                    .joined(separator: "\n")
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Select a driver to see its details.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func facts(of driver: Driver) -> [(name: String, value: String)] {
        var facts: [(String, String)] = [
            ("Kind", driver.kind.rawValue),
            ("Version", driver.version.isEmpty ? "Unknown" : driver.version),
            ("Vendor", driver.vendor),
        ]
        if let status = driver.status { facts.append(("Status", status)) }
        if let index = driver.loadIndex { facts.append(("Load index", String(index))) }
        if let count = driver.referencedBy { facts.append(("Referenced by", "\(count) extensions")) }
        if let size = driver.loadSize { facts.append(("Size", size.memoryFormatted)) }
        if let wired = driver.wiredSize { facts.append(("Wired memory", wired.memoryFormatted)) }
        if let count = driver.dependencyCount { facts.append(("Depends on", "\(count) extensions")) }
        if let uuid = driver.uuid { facts.append(("UUID", uuid)) }
        facts.append(("Location", driver.path ?? (driver.kind == .systemExtension
            ? "Managed by macOS"
            : "Built into the kernel")))
        return facts
    }

    private func note(for driver: Driver) -> String? {
        switch (driver.kind, driver.isApple, driver.isLoaded) {
        case (.kernelExtension, true, true):
            "This is an Apple kernel extension. System Integrity Protection does not permit unloading it, and the system depends on it while running."
        case (.kernelExtension, false, _):
            "Third-party kernel extensions are managed in System Settings › Privacy & Security."
        case (.systemExtension, _, _):
            "System extensions are turned on and off in System Settings › General › Login Items & Extensions."
        default:
            nil
        }
    }
}
