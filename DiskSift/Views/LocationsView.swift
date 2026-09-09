import AppKit
import SwiftUI

struct LocationsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Scan locations")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Projects are discovered from the macOS index and Git worktree registrations. Added folders and known Xcode storage are checked directly.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Panel {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(DiskSiftTheme.node)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Automatic project discovery")
                                    .font(.body.weight(.medium))
                                Text("Spotlight index · Xcode DerivedData checked directly")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Always on")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)

                        ForEach(model.scanRoots, id: \.path) { root in
                            Divider()
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(DiskSiftTheme.node)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent)
                                        .font(.body.weight(.medium))
                                    Text(root.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button {
                                    model.removeScanRoot(root)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove scan location")
                            }
                            .padding(.vertical, 12)
                        }

                        Divider()
                        Button {
                            chooseFolder()
                        } label: {
                            Label("Add Folder…", systemImage: "plus")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 14)

                        Text("Privacy-managed folders and other Library contents are only checked when you add them here. Xcode DerivedData is checked at its known path.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Refresh policy")
                        .font(.title3.weight(.semibold))

                    Panel {
                        VStack(alignment: .leading, spacing: 18) {
                            policyRow(
                                icon: "magnifyingglass",
                                title: "Indexed discovery",
                                detail: "DiskSift uses the macOS index and checks registered Git worktrees directly, including hidden checkouts. Privacy-managed locations still require an added folder."
                            )
                            Divider()
                            policyRow(
                                icon: "gauge.with.dots.needle.50percent",
                                title: "Targeted measurement",
                                detail: "Only discovered build, dependency, and Xcode DerivedData folders are measured at utility priority."
                            )
                            Divider()
                            policyRow(
                                icon: "arrow.triangle.2.circlepath",
                                title: "Capacity refreshes separately",
                                detail: "Free-space updates never trigger a directory walk."
                            )
                        }
                    }
                }

                if model.snapshot.finishedAt != .distantPast {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Last scan")
                            .font(.title3.weight(.semibold))
                        Panel {
                            HStack(spacing: 28) {
                                diagnostic("Duration", value: scanDuration)
                                diagnostic("Entries measured", value: (model.snapshot.filesVisited + model.snapshot.directoriesVisited).formatted())
                                diagnostic("Artifacts", value: model.snapshot.artifacts.count.formatted())
                                diagnostic("Skipped", value: model.snapshot.errorsSkipped.formatted())
                                Spacer()
                            }
                        }
                    }
                }

                HStack {
                    Button(model.isScanning ? "Cancel Scan" : "Refresh Inventory") {
                        model.isScanning ? model.cancelScan() : model.startScan()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DiskSiftTheme.node)

                    if model.isScanning, let progress = model.scanProgress {
                        ProgressView()
                            .controlSize(.small)
                        Text("\(progress.entriesVisited.formatted()) entries checked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Scan Locations")
    }

    private var scanDuration: String {
        let seconds = model.snapshot.finishedAt.timeIntervalSince(model.snapshot.startedAt)
        return Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }

    private func policyRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(DiskSiftTheme.node)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func diagnostic(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to scan"
        panel.prompt = "Add Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.addScanRoot(url)
        }
    }
}
