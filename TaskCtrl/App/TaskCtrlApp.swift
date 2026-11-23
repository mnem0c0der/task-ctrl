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

    var body: some Scene {
        WindowGroup {
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
    }
}
