import Foundation
import Observation

/// Owns the current scan and the folder the user is looking at.
/// Lives at app level so a scan survives switching sidebar tabs.
@MainActor
@Observable
final class DiskScanModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var progress = DiskScanner.Progress()
    private(set) var root: DiskNode?
    /// Breadcrumb from the scan root down to the folder being shown.
    private(set) var path: [DiskNode] = []
    private(set) var unreadableCount = 0
    private(set) var entryCount = 0
    private(set) var duration: Duration = .zero
    /// Space per file category in the last scan, indexed by `FileCategory.rawValue`.
    private(set) var categorySizes: [UInt64] = []
    private(set) var largestFiles: [DiskScanner.LargeFile] = []
    /// Earlier scans, newest first; kept between launches.
    private(set) var history: [ScanRecord] = ScanRecord.load()

    struct ScanRecord: Codable, Identifiable, Sendable {
        let path: String
        let size: UInt64
        let date: Date

        var id: Date { date }

        private static let key = "scanHistory"

        static func load() -> [ScanRecord] {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([ScanRecord].self, from: data)) ?? []
        }

        static func save(_ records: [ScanRecord]) {
            UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: key)
        }
    }

    /// Folder to scan; remembered between launches.
    var target: URL {
        didSet {
            guard target != oldValue else { return }
            UserDefaults.standard.set(target.path(percentEncoded: false), forKey: Self.targetKey)
            reset()
        }
    }

    private static let targetKey = "scanTarget"

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.targetKey) {
            target = URL(filePath: saved, directoryHint: .isDirectory)
        } else {
            target = FileManager.default.homeDirectoryForCurrentUser
        }
    }

    private var task: Task<Void, Never>?

    var current: DiskNode? { path.last }

    func scan() {
        task?.cancel()
        root = nil
        path = []
        progress = DiskScanner.Progress()
        phase = .scanning

        let target = target
        task = Task {
            let started = ContinuousClock.now
            let worker = Task.detached(priority: .userInitiated) {
                try DiskScanner.scan(target) { update in
                    Task { @MainActor [weak self] in self?.progress = update }
                }
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                root = result.root
                path = [result.root]
                unreadableCount = result.unreadable
                entryCount = result.entries
                categorySizes = result.categorySizes
                largestFiles = result.largestFiles
                history.insert(
                    ScanRecord(path: target.path(percentEncoded: false), size: result.root.size, date: Date()),
                    at: 0
                )
                history = Array(history.prefix(10))
                ScanRecord.save(history)
                duration = ContinuousClock.now - started
                phase = .finished
            } catch is CancellationError {
                // cancel() already put the model back to idle.
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .scanning { phase = .idle }
    }

    func open(_ node: DiskNode) {
        guard node.isDirectory else { return }
        path.append(node)
    }

    /// Jumps back to a breadcrumb level.
    func pop(to index: Int) {
        guard path.indices.contains(index) else { return }
        path.removeSubrange((index + 1)...)
    }

    /// Moves the item to the Trash and takes it out of the tree.
    func moveToTrash(_ node: DiskNode) throws {
        guard let parent = node.parent else { return }
        try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        parent.children.removeAll { $0 === node }
        var ancestor: DiskNode? = parent
        while let folder = ancestor {
            folder.size = folder.size >= node.size ? folder.size - node.size : 0
            ancestor = folder.parent
        }
    }

    private func reset() {
        task?.cancel()
        task = nil
        root = nil
        path = []
        categorySizes = []
        largestFiles = []
        phase = .idle
    }
}
