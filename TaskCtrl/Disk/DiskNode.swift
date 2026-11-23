import Foundation
import Observation

/// One folder or large file in a scanned tree.
///
/// Built by `DiskScanner` on a background task and handed to the main actor
/// once complete; after that it is only touched from the main actor, which is
/// what makes the unchecked conformance sound.
@Observable
final class DiskNode: Identifiable, @unchecked Sendable {
    let name: String
    let isDirectory: Bool
    /// Set only on the scan root; every other node derives its URL from its parent.
    private let rootURL: URL?
    @ObservationIgnored weak var parent: DiskNode?

    /// Allocated size on disk in bytes, including everything below.
    var size: UInt64 = 0
    /// Subfolders and large files, biggest first.
    var children: [DiskNode] = []
    /// Files directly inside this folder that are too small to list individually.
    var smallFilesSize: UInt64 = 0
    var smallFilesCount = 0
    /// Kind of the file, or for a folder the kind that fills most of it.
    var category: FileCategory = .other

    init(name: String, isDirectory: Bool, rootURL: URL? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.rootURL = rootURL
    }

    var url: URL {
        if let rootURL { return rootURL }
        guard let parent else { return URL(filePath: name) }
        return parent.url.appending(path: name, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }
}
