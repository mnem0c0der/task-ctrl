import Observation
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case performance = "Performance"
    case processes = "Processes"
    case sensors = "Sensors"
    case appleSilicon = "Apple Silicon"
    case connections = "Connections"
    case systemInfo = "System Info"
    case startup = "Startup apps"
    case users = "Users"
    case services = "Services"
    case installedApps = "Installed Apps"
    case drivers = "Drivers"
    case disk = "Disk Space"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .summary: "gauge.with.dots.needle.67percent"
        case .performance: "waveform.path.ecg"
        case .processes: "list.bullet.rectangle"
        case .sensors: "thermometer.medium"
        case .appleSilicon: "cpu"
        case .connections: "network"
        case .systemInfo: "info.circle"
        case .startup: "power"
        case .users: "person.2"
        case .services: "gearshape.2"
        case .installedApps: "square.grid.2x2"
        case .drivers: "cpu.fill"
        case .disk: "internaldrive"
        }
    }
}

/// Which tab is showing, shared so one tab can send the user to another.
@MainActor
@Observable
final class AppNavigation {
    var sidebar: SidebarItem? = .summary
    /// A process the Processes tab should select and show details for,
    /// set just before switching to it.
    var processToReveal: pid_t?

    func revealProcess(_ pid: pid_t) {
        processToReveal = pid
        sidebar = .processes
    }
}

struct RootView: View {
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation

        NavigationSplitView {
            List(SidebarItem.allCases, selection: $navigation.sidebar) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch navigation.sidebar ?? .summary {
            case .summary: SummaryView()
            case .performance: PerformanceView()
            case .processes: ProcessesView()
            case .sensors: SensorsView()
            case .appleSilicon: AppleSiliconView()
            case .connections: ConnectionsView()
            case .systemInfo: SystemInfoView()
            case .startup: StartupView()
            case .users: UsersView()
            case .services: ServicesView()
            case .installedApps: InstalledAppsView()
            case .drivers: DriversView()
            case .disk: DiskView()
            }
        }
    }
}
