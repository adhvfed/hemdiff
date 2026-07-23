import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable {
    case overview
    case reclaim
    case locations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .reclaim: "Reclaim"
        case .locations: "Scan Locations"
        }
    }

    var icon: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .reclaim: "trash"
        case .locations: "folder.badge.gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var destination: AppDestination? = .overview

    var body: some View {
        NavigationSplitView {
            List(AppDestination.allCases, selection: $destination) { item in
                Label(item.title, systemImage: item.icon)
                    .tag(item)
                    .padding(.vertical, 3)
            }
            .navigationSplitViewColumnWidth(min: 184, ideal: 206)
            .safeAreaInset(edge: .bottom) {
                SidebarStatus()
                    .padding(12)
            }
        } detail: {
            Group {
                switch destination ?? .overview {
                case .overview:
                    OverviewView(openReclaim: { destination = .reclaim })
                case .reclaim:
                    ReclaimView()
                case .locations:
                    LocationsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.isScanning ? model.cancelScan() : model.startScan()
                } label: {
                    Label(
                        model.isScanning ? "Cancel Scan" : "Scan Now",
                        systemImage: model.isScanning ? "stop.fill" : "arrow.clockwise"
                    )
                }
                .help(model.isScanning ? "Cancel the current scan" : "Scan configured locations")
            }
        }
    }
}

private struct SidebarStatus: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isScanning ? DiskSiftTheme.node : .secondary.opacity(0.55))
                    .frame(width: 7, height: 7)
                Text(model.isScanning ? "Scanning" : "Monitor ready")
                    .font(.caption.weight(.medium))
            }

            if let progress = model.scanProgress {
                Text("\(progress.entriesVisited.formatted()) entries · \(progress.artifactsFound) found")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if model.snapshot.finishedAt != .distantPast {
                Text("Updated \(model.snapshot.finishedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Waiting for first scan")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
