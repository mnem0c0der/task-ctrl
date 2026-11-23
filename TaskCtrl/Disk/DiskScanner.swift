import Darwin
import Foundation

/// Walks a folder with fts(3) and builds a size tree.
enum DiskScanner {
    struct Progress: Sendable {
        var entries = 0
        var bytes: UInt64 = 0
        var currentPath = ""
    }

    struct LargeFile: Sendable, Identifiable {
        let path: String
        let size: UInt64
        let category: FileCategory

        var id: String { path }
    }

    struct Result: Sendable {
        let root: DiskNode
        let entries: Int
        /// Folders and files the system refused to let us read.
        let unreadable: Int
        /// Space taken by each kind of file, indexed by `FileCategory.rawValue`.
        let categorySizes: [UInt64]
        /// The biggest individual files, largest first.
        let largestFiles: [LargeFile]
    }

    /// Files smaller than this are summed into their folder instead of getting a node.
    static let defaultMinimumFileSize: UInt64 = 1 << 20
    /// How many of the biggest files to remember.
    static let largestFileCount = 100

    private static let systemRoots = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/opt"]

    /// Blocking; call from a background task. Checks for task cancellation as it goes.
    static func scan(
        _ url: URL,
        minimumFileSize: UInt64 = defaultMinimumFileSize,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) throws -> Result {
        let rootPath = url.path(percentEncoded: false)
        guard let cPath = strdup(rootPath) else { throw POSIXError(.ENOMEM) }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]

        // PHYSICAL: do not follow symlinks. XDEV: stay on the starting volume.
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { fts_close(stream) }

        /// Totals are accumulated here and written to the node once, when its folder closes.
        struct Frame {
            let node: DiskNode
            var size: UInt64 = 0
            var children: [DiskNode] = []
            var smallFilesSize: UInt64 = 0
            var smallFilesCount = 0
            /// Bytes per file category, one lane per `FileCategory`.
            var categories = SIMD8<UInt64>()
        }

        var stack: [Frame] = []
        var root: DiskNode?
        var seenHardLinks = Set<UInt64>()
        var state = Progress()
        var unreadable = 0
        var totals = SIMD8<UInt64>()

        // Everything inside an app bundle counts as "Applications", and
        // everything under a Library folder or a system root as "System"
        // unless its extension says otherwise. These remember the stack depth
        // at which such a folder was entered.
        var applicationDepth: Int?
        var systemDepth: Int? = systemRoots.contains { rootPath == $0 || rootPath.hasPrefix($0 + "/") } ? 0 : nil

        var largest: [LargeFile] = []
        var largestThreshold: UInt64 = 0

        func close(_ frame: Frame) {
            let node = frame.node
            node.size = frame.size
            node.children = frame.children.sorted { $0.size > $1.size }
            node.smallFilesSize = frame.smallFilesSize
            node.smallFilesCount = frame.smallFilesCount
            // A folder takes the colour of whatever fills most of it.
            var dominant = FileCategory.other
            var most: UInt64 = 0
            for category in FileCategory.allCases where frame.categories[Int(category.rawValue)] > most {
                most = frame.categories[Int(category.rawValue)]
                dominant = category
            }
            node.category = dominant

            if let depth = applicationDepth, depth > stack.count { applicationDepth = nil }
            if let depth = systemDepth, depth > stack.count { systemDepth = nil }

            guard !stack.isEmpty else { return }
            node.parent = stack[stack.count - 1].node
            stack[stack.count - 1].size += frame.size
            stack[stack.count - 1].categories &+= frame.categories
            stack[stack.count - 1].children.append(node)
        }

        while let entry = fts_read(stream) {
            state.entries += 1
            if state.entries % 4096 == 0 {
                try Task.checkCancellation()
                state.currentPath = String(cString: entry.pointee.fts_path)
                progress(state)
            }

            let info = Int32(entry.pointee.fts_info)
            let allocated = entry.pointee.fts_statp.map { UInt64(max($0.pointee.st_blocks, 0)) * 512 } ?? 0

            switch info {
            case FTS_D:
                let path = String(cString: entry.pointee.fts_path)
                let node: DiskNode
                if stack.isEmpty {
                    node = DiskNode(name: rootPath, isDirectory: true, rootURL: url)
                    root = node
                } else {
                    node = DiskNode(name: (path as NSString).lastPathComponent, isDirectory: true)
                }
                var frame = Frame(node: node, size: allocated)
                frame.categories[Int(FileCategory.other.rawValue)] = allocated
                totals[Int(FileCategory.other.rawValue)] &+= allocated
                stack.append(frame)
                state.bytes += allocated

                if applicationDepth == nil, path.hasSuffix(".app") { applicationDepth = stack.count }
                if systemDepth == nil, node.name == "Library" { systemDepth = stack.count }

            case FTS_DP, FTS_DNR:
                if info == FTS_DNR { unreadable += 1 }
                // An unreadable folder is reported in place of its closing visit.
                if stack.count == Int(entry.pointee.fts_level) + 1 {
                    close(stack.removeLast())
                }

            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard !stack.isEmpty, let stat = entry.pointee.fts_statp else { continue }
                // Count a hard-linked file once, the way du does.
                if stat.pointee.st_nlink > 1, !seenHardLinks.insert(stat.pointee.st_ino).inserted {
                    continue
                }

                let category: FileCategory
                if applicationDepth != nil {
                    category = .applications
                } else if let known = categoryByExtension(entry) {
                    category = known
                } else {
                    category = systemDepth != nil ? .system : .other
                }
                let lane = Int(category.rawValue)

                state.bytes += allocated
                totals[lane] &+= allocated
                stack[stack.count - 1].size += allocated
                stack[stack.count - 1].categories[lane] &+= allocated

                if allocated >= minimumFileSize {
                    let path = String(cString: entry.pointee.fts_path)
                    let node = DiskNode(name: (path as NSString).lastPathComponent, isDirectory: false)
                    node.size = allocated
                    node.category = category
                    node.parent = stack[stack.count - 1].node
                    stack[stack.count - 1].children.append(node)
                } else {
                    stack[stack.count - 1].smallFilesSize += allocated
                    stack[stack.count - 1].smallFilesCount += 1
                }

                if allocated > largestThreshold {
                    largest.append(LargeFile(
                        path: String(cString: entry.pointee.fts_path), size: allocated, category: category
                    ))
                    // Trim only now and then, so the list stays cheap to maintain.
                    if largest.count >= largestFileCount * 4 {
                        largest.sort { $0.size > $1.size }
                        largest.removeLast(largest.count - largestFileCount)
                        largestThreshold = largest.last?.size ?? 0
                    }
                }

            case FTS_ERR, FTS_NS:
                unreadable += 1

            default:
                break
            }
        }

        // Only reached with open frames if the walk stopped early.
        while let frame = stack.popLast() { close(frame) }

        guard let root else { throw POSIXError(.ENOTDIR) }
        largest.sort { $0.size > $1.size }
        return Result(
            root: root,
            entries: state.entries,
            unreadable: unreadable,
            categorySizes: FileCategory.allCases.map { totals[Int($0.rawValue)] },
            largestFiles: Array(largest.prefix(largestFileCount))
        )
    }

    /// Looks at the file's extension straight in fts's path buffer, without
    /// building a string: this runs for every file on the disk.
    private static func categoryByExtension(_ entry: UnsafeMutablePointer<FTSENT>) -> FileCategory? {
        guard let path = entry.pointee.fts_path else { return nil }
        let length = Int(entry.pointee.fts_pathlen)
        var index = length - 1
        // Walk back to the last dot of the file name; give up at a slash or
        // once the extension would be longer than any we know.
        while index >= 0, length - index <= 9 {
            let byte = UInt8(bitPattern: path[index])
            if byte == UInt8(ascii: "/") { return nil }
            if byte == UInt8(ascii: ".") {
                let bytes = UnsafeBufferPointer(start: path + index + 1, count: length - index - 1)
                guard let key = FileCategory.extensionKey(bytes.lazy.map { UInt8(bitPattern: $0) }) else {
                    return nil
                }
                return FileCategory.byExtensionKey[key]
            }
            index -= 1
        }
        return nil
    }
}
