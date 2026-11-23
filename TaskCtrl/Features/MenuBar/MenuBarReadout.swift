import AppKit
import SwiftUI

/// Settings shared by the menu bar item and the Settings window.
enum MenuBarSettings {
    static let isShownKey = "showsMenuBarReadout"
}

// MARK: - Label

/// What sits in the menu bar: CPU, GPU and memory, each a small caption over
/// its percentage.
struct MenuBarReadout: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let snapshot = monitor.snapshot
        let columns = [
            ("CPU", snapshot.cpu.total),
            ("GPU", snapshot.sensors.gpuUtilization),
            ("MEM", snapshot.memory.fraction),
        ].map { (label: $0.0, value: Self.percent($0.1)) }

        // The menu bar shows only text or an image for a label, so the
        // three columns are drawn into one picture.
        Image(nsImage: Self.image(columns))
            .accessibilityLabel(columns.map { "\($0.label) \($0.value)" }.joined(separator: ", "))
            // The window may be closed while the menu bar item stays.
            .task { monitor.start() }
    }

    private static func percent(_ fraction: Double?) -> String {
        fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    // MARK: Drawing

    /// Wide enough for "100%", so the item keeps its width as numbers change.
    private static let columnWidth = 32.0
    private static let columnSpacing = 5.0
    private static let height = 22.0
    private static let captionFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)

    private static func image(_ columns: [(label: String, value: String)]) -> NSImage {
        let width = Double(columns.count) * columnWidth + Double(max(columns.count - 1, 0)) * columnSpacing
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            for (index, column) in columns.enumerated() {
                let left = Double(index) * (columnWidth + columnSpacing)
                draw(column.label, font: captionFont, left: left, bottom: 11.5)
                draw(column.value, font: valueFont, left: left, bottom: -0.5)
            }
            return true
        }
        // A template is tinted by the menu bar itself, light or dark.
        image.isTemplate = true
        return image
    }

    private static func draw(_ text: String, font: NSFont, left: Double, bottom: Double) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = string.size()
        string.draw(at: NSPoint(x: left + (columnWidth - size.width) / 2, y: bottom))
    }
}

// MARK: - Menu

/// The menu under the menu bar item.
struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    /// Identifier of the main window's scene.
    static let windowID = "main"

    var body: some View {
        Button("Open TaskCtrl") { showMainWindow() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit TaskCtrl") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Brings the window forward, or makes a new one if it was closed.
    private func showMainWindow() {
        NSApp.activate()
        if let window = MainWindow.current, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: Self.windowID)
        }
    }
}

// MARK: - Main window

/// Remembers the window the main view sits in, so the menu bar item can
/// bring it forward instead of opening a second one.
@MainActor
enum MainWindow {
    fileprivate(set) static weak var current: NSWindow?
}

/// Put behind the main view to report its window.
struct MainWindowTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TrackingView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class TrackingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainWindow.current = window }
        }
    }
}
