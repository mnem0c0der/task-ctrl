import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Section list on the left, the selected section's report on the right.
struct SystemInfoView: View {
    @Environment(SystemInfoModel.self) private var model
    @AppStorage("systemInfoCategory") private var selection: SystemInfoCategory = .hardware
    @State private var exportError: String?

    var body: some View {
        HStack(spacing: 0) {
            categoryList
                .frame(width: 280)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Dashboard.pageFill)
        .navigationTitle("System Info")
        .toolbar {
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") {
                    model.load(selection, force: true)
                }
                .help("Read this section again")
            }
        }
        .task(id: selection) { model.load(selection) }
        .alert(
            "Couldn’t export",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - List

    private var categoryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SystemInfoCategory.Group.allCases, id: \.self) { group in
                    Text(group.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 14)
                        .padding(.bottom, 4)

                    ForEach(SystemInfoCategory.allCases.filter { $0.group == group }) { category in
                        Button {
                            selection = category
                        } label: {
                            Label(category.title, systemImage: category.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    category == selection ? Color.accentColor.opacity(0.85) : .clear,
                                    in: .rect(cornerRadius: 6)
                                )
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(category == selection ? .isSelected : [])
                    }
                }
            }
            .padding(10)
        }
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: selection.symbol)
                    .font(.title2)
                Text(selection.title)
                    .font(.title2.weight(.semibold))
                Spacer()
                Menu("Export…") {
                    Button("Selected category…") {
                        export([selection], suggestedName: selection.title)
                    }
                    Button("All loaded categories…") {
                        export(model.loadedCategories, suggestedName: "System Info")
                    }
                    .disabled(model.loadedCategories.isEmpty)
                }
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            switch model.sections[selection] {
            case .loading, nil:
                ProgressView("Reading \(selection.title)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView(
                    "Couldn’t read this section",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .loaded(let rows, _):
                if rows.isEmpty {
                    ContentUnavailableView(
                        "Nothing to show",
                        systemImage: selection.symbol,
                        description: Text("This Mac reports no \(selection.title) information.")
                    )
                } else {
                    report(rows)
                }
            }
        }
    }

    private func report(_ rows: [SystemInfoRow]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    Group {
                        if row.isHeading {
                            Text(row.title)
                                .font(.headline)
                                .padding(.top, row.id == 0 ? 0 : 12)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(row.title)
                                    .frame(width: 250, alignment: .leading)
                                Text(row.value ?? "")
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.leading, CGFloat(row.depth) * 10)
                    .padding(.vertical, 7)
                    if !row.isHeading { Divider() }
                }
            }
            .font(.body.monospacedDigit())
            .padding(20)
        }
    }

    // MARK: - Export

    /// Asks where to save; the format picker in the dialog (text or JSON)
    /// decides what gets written.
    private func export(_ categories: [SystemInfoCategory], suggestedName: String) {
        guard !categories.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName.replacingOccurrences(of: "/", with: "-")
        panel.allowedContentTypes = [.plainText, .json]
        panel.showsContentTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format: SystemInfoModel.Format = url.pathExtension.lowercased() == "json" ? .json : .text
        Task {
            do {
                let body = try await model.export(categories, as: format)
                try body.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}
