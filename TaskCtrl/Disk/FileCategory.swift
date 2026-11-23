import SwiftUI

/// Broad kind of a file, used to colour the disk map and total up space.
enum FileCategory: UInt8, CaseIterable, Sendable, Identifiable {
    case media, documents, code, archives, applications, system, other

    var id: Self { self }

    var title: String {
        switch self {
        case .media: "Media"
        case .documents: "Documents"
        case .code: "Code"
        case .archives: "Archives"
        case .applications: "Applications"
        case .system: "System"
        case .other: "Other"
        }
    }

    var color: Color {
        switch self {
        case .media: Color(red: 0.98, green: 0.42, blue: 0.42)
        case .documents: Color(red: 0.35, green: 0.80, blue: 0.45)
        case .code: Color(red: 0.40, green: 0.65, blue: 1.00)
        case .archives: Color(red: 0.98, green: 0.80, blue: 0.30)
        case .applications: Color(red: 0.70, green: 0.50, blue: 0.98)
        case .system: Color(red: 0.60, green: 0.66, blue: 0.76)
        case .other: Color(red: 0.42, green: 0.46, blue: 0.56)
        }
    }

    private static let extensions: [FileCategory: [String]] = [
        .media: [
            "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "raw", "cr2", "nef",
            "dng", "psd", "svg", "ico", "icns", "mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv",
            "mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg", "opus", "mid", "caf",
        ],
        .documents: [
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf",
            "md", "csv", "epub", "odt", "ods", "tex",
        ],
        .code: [
            "swift", "h", "m", "mm", "c", "cc", "cpp", "hpp", "rs", "go", "py", "rb", "js", "ts", "jsx",
            "tsx", "java", "kt", "cs", "php", "sh", "html", "css", "scss", "json", "xml", "yml", "yaml",
            "toml", "sql", "o", "a", "class", "jar", "pyc", "map", "lock", "gradle",
        ],
        .archives: [
            "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg", "xip", "zst", "cab",
        ],
    ]

    /// Extension → category, with the extension packed into an integer so the
    /// scanner can look one up for every file without allocating a string.
    static let byExtensionKey: [UInt64: FileCategory] = {
        var table: [UInt64: FileCategory] = [:]
        for (category, list) in extensions {
            for name in list {
                if let key = extensionKey(Array(name.utf8)) { table[key] = category }
            }
        }
        return table
    }()

    /// Packs up to eight lower-cased ASCII bytes into one integer.
    static func extensionKey(_ bytes: some Collection<UInt8>) -> UInt64? {
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        var key: UInt64 = 0
        for byte in bytes {
            let lower = (byte >= 65 && byte <= 90) ? byte + 32 : byte
            key = key << 8 | UInt64(lower)
        }
        return key
    }
}
