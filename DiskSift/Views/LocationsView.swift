import AppKit
import SwiftUI

struct LocationsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Scan Locations")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                }

                Panel {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(DiskSiftTheme.node)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Automatic scan")
                                    .font(.body.weight(.medium))
                                Text("Indexed projects, Git worktrees & Xcode builds")
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

                        Text("Add folders to classify their files, including Downloads, Movies, or Documents.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                    }
                }

                if model.snapshot.finishedAt != .distantPast {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Last scan")
                            .font(.title3.weight(.semibold))
                        Panel {
                            HStack(spacing: 28) {
                                diagnostic("Duration", value: scanDuration)
                                diagnostic("Build folders", value: model.snapshot.artifacts.count.formatted())
                                diagnostic("Files", value: model.snapshot.content.count.formatted())
                                diagnostic("Skipped", value: model.snapshot.errorsSkipped.formatted())
                                Spacer()
                            }
                        }
                    }
                }

                HStack {
                    Button(model.isScanning ? "Cancel Scan" : "Scan Now") {
                        model.isScanning ? model.cancelScan() : model.startScan()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DiskSiftTheme.node)

                    if model.isScanning, let progress = model.scanProgress {
                        ProgressView()
                            .controlSize(.small)
                        Text(progress.summary)
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
