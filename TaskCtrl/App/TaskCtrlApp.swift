import AppKit
import SwiftUI

@main
struct TaskCtrlApp: App {
    @State private var monitor = SystemMonitor()
    @State private var diskScan = DiskScanModel()
    @State private var helper = HelperManager()
    @State private var systemInfo = SystemInfoModel()
    @State private var startupItems = StartupItemsModel()
    @State private var services = ServicesModel()
    @State private var navigation = AppNavigation()
    @State private var connections = ConnectionsModel()
    @State private var installedApps = InstalledAppsModel()
    @State private var drivers = DriversModel()
    @AppStorage(MenuBarSettings.showsUsageKey) private var showsMenuBarUsage = true
    @AppStorage(MenuBarSettings.showsNetworkKey) private var showsMenuBarNetwork = true

    var body: some Scene {
        WindowGroup(id: MenuBarMenu.windowID) {
            RootView()
                .environment(monitor)
                .environment(diskScan)
                .environment(helper)
                .environment(systemInfo)
                .environment(startupItems)
                .environment(services)
                .environment(navigation)
                .environment(connections)
                .environment(installedApps)
                .environment(drivers)
                .frame(minWidth: 1040, minHeight: 620)
                .background(MainWindowTracker())
                // The dashboard is designed as a dark instrument panel.
                .preferredColorScheme(.dark)
                .task { monitor.start() }
                // Approval happens in System Settings, so re-check on return.
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                ) { _ in helper.refresh() }
        }
        .defaultSize(width: 1180, height: 780)

        Settings {
            SettingsView()
                .environment(helper)
        }

        // One item holds both readouts; it is there while either is on.
        // Dragging it out of the menu bar turns both off.
        MenuBarExtra(isInserted: Binding(
            get: { showsMenuBarUsage || showsMenuBarNetwork },
            set: { if !$0 { showsMenuBarUsage = false; showsMenuBarNetwork = false } }
        )) {
            MenuBarMenu()
        } label: {
            MenuBarReadout()
                .environment(monitor)
        }
    }
}
