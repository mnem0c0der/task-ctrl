import SwiftUI

/// Explains what the helper is for and offers the one action that makes sense right now.
struct HelperStatusView: View {
    @Environment(HelperManager.self) private var helper

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label(title, systemImage: symbol)
                    .font(.callout)
                Spacer()
                action
            }
            if let error = helper.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var title: String {
        switch helper.state {
        case .notInstalled:
            "Install the helper to see CPU and memory of system processes and to quit them."
        case .requiresApproval:
            "Allow TaskCtrl in System Settings › General › Login Items & Extensions to finish."
        case .enabled:
            "The helper is installed. It runs with administrator rights only while TaskCtrl is open."
        case .outdated:
            "The installed helper is from an older version of TaskCtrl and lacks some features."
        case .unavailable:
            "The helper needs a build signed with a developer team; this build has none."
        }
    }

    private var symbol: String {
        switch helper.state {
        case .enabled: "checkmark.shield"
        case .requiresApproval: "hourglass"
        case .notInstalled: "lock.shield"
        case .outdated: "arrow.triangle.2.circlepath"
        case .unavailable: "exclamationmark.shield"
        }
    }

    @ViewBuilder
    private var action: some View {
        switch helper.state {
        case .notInstalled:
            Button("Install Helper…") { helper.install() }
        case .requiresApproval:
            Button("Open Settings") { helper.openApprovalSettings() }
        case .enabled:
            Button("Remove") { Task { await helper.uninstall() } }
        case .outdated:
            Button("Update Helper…") { Task { await helper.update() } }
        case .unavailable:
            EmptyView()
        }
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Privileged helper") {
                HelperStatusView()
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
