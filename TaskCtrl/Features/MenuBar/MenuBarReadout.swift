import AppKit
import SwiftUI

/// Settings shared by the menu bar item and the Settings window.
enum MenuBarSettings {
    /// CPU, GPU and memory.
    static let showsUsageKey = "showsMenuBarReadout"
    static let showsNetworkKey = "showsMenuBarNetwork"
}

// MARK: - Label

/// What sits in the menu bar: CPU, GPU and memory, each a small caption over
/// its percentage, then upload and download speed one above the other.
struct MenuBarReadout: View {
    @Environment(SystemMonitor.self) private var monitor
    @AppStorage(MenuBarSettings.showsUsageKey) private var showsUsage = true
    @AppStorage(MenuBarSettings.showsNetworkKey) private var showsNetwork = true

    var body: some View {
        let snapshot = monitor.snapshot
        let usage = showsUsage ? [
            ("CPU", snapshot.cpu.total),
            ("GPU", snapshot.sensors.gpuUtilization),
            ("MEM", snapshot.memory.fraction),
        ].map { (label: $0.0, value: Self.percent($0.1)) } : []
        let network = showsNetwork ? (
            up: Self.rate(snapshot.activity.networkOut), down: Self.rate(snapshot.activity.networkIn)
        ) : nil

        // The menu bar shows only text or an image for a label, so
        // everything is drawn into one picture.
        Image(nsImage: Self.image(usage: usage, network: network))
            .accessibilityLabel(
                (usage.map { "\($0.label) \($0.value)" }
                    + (network.map { ["Upload \($0.up)", "Download \($0.down)"] } ?? []))
                    .joined(separator: ", ")
            )
            // The window may be closed while the menu bar item stays.
            .task { monitor.start() }
    }

    private static func percent(_ fraction: Double?) -> String {
        fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    /// Bytes per second, short enough for the menu bar: "0 B/s", "12.3 kB/s",
    /// "148 MB/s". Never more than three digits, so the width stays put.
    private static func rate(_ bytesPerSecond: Double) -> String {
        var value = max(bytesPerSecond, 0)
        var unit = "B"
        for next in ["kB", "MB", "GB"] where value >= 999.5 {
            value /= 1000
            unit = next
        }
        let digits = unit == "B" || value >= 99.95 ? 0 : 1
        return "\(value.formatted(.number.precision(.fractionLength(digits)))) \(unit)/s"
    }

    // MARK: Drawing

    /// Wide enough for "100%", so the item keeps its width as numbers change.
    private static let columnWidth = 32.0
    private static let columnSpacing = 5.0
    /// Wide enough for an arrow and "999 MB/s".
    private static let networkWidth = 62.0
    private static let height = 22.0
    private static let captionFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    private static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)

    private static func image(
        usage: [(label: String, value: String)], network: (up: String, down: String)?
    ) -> NSImage {
        let usageWidth = Double(usage.count) * (columnWidth + columnSpacing)
        let width = max(usageWidth + (network == nil ? -columnSpacing : networkWidth), 1)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            for (index, column) in usage.enumerated() {
                let left = Double(index) * (columnWidth + columnSpacing)
                draw(column.label, font: captionFont, bottom: 11.5, centeredIn: left...(left + columnWidth))
                draw(column.value, font: valueFont, bottom: -0.5, centeredIn: left...(left + columnWidth))
            }
            if let network {
                for (arrow, text, bottom) in [("↑", network.up, 10.5), ("↓", network.down, -0.5)] {
                    draw("\(arrow) \(text)", font: rateFont, bottom: bottom, left: usageWidth + 3)
                }
            }
            return true
        }
        // A template is tinted by the menu bar itself, light or dark.
        image.isTemplate = true
        return image
    }

    private static func string(_ text: String, _ font: NSFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
    }

    private static func draw(_ text: String, font: NSFont, bottom: Double, centeredIn range: ClosedRange<Double>) {
        let string = string(text, font)
        let middle = (range.lowerBound + range.upperBound) / 2
        string.draw(at: NSPoint(x: middle - string.size().width / 2, y: bottom))
    }

    private static func draw(_ text: String, font: NSFont, bottom: Double, left: Double) {
        string(text, font).draw(at: NSPoint(x: left, y: bottom))
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
