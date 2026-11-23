import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Icon of the app a process belongs to; helpers get the icon of the outer app.
struct ProcessIcon: View {
    let path: String

    var body: some View {
        Image(nsImage: IconCache.shared.icon(forExecutable: path))
            .resizable()
            .interpolation(.high)
            .frame(width: 16, height: 16)
    }
}

@MainActor
private final class IconCache {
    static let shared = IconCache()

    private var icons: [String: NSImage] = [:]
    private let generic = NSWorkspace.shared.icon(for: .unixExecutable)

    func icon(forExecutable path: String) -> NSImage {
        // Everything outside an app bundle shares one generic icon.
        guard let range = path.range(of: ".app/") else { return generic }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        if let cached = icons[bundlePath] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: bundlePath)
        icons[bundlePath] = icon
        return icon
    }
}
