import AppKit
import SwiftUI

struct LocationsView: View {
    @State private var findsProjects = false
    @EnvironmentObject private var model: AppModel

    @State private var search = ""
    private var roots: [URL] {
        model.scanRoots.filter { search.isEmpty || $0.path.localizedStandardContains(search) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan Locations").font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-0.6)
                    Text("Folders to measure and check for build output.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { findsProjects = true } label: { Label("Find Projects", systemImage: "sparkle.magnifyingglass") }
                Button { chooseFolder() } label: { Label("Add Folder…", systemImage: "plus") }
                    .buttonStyle(HemdiffButtonStyle(emphasis: .primary))
            }
            HStack(spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(DiskSiftTheme.node)
                Text("Indexed projects, Git worktrees and Xcode builds are also checked.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(DiskSiftTheme.node.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                ReviewSearchField(placeholder: "Filter locations", text: $search)
                Text("\(model.scanRoots.count) folders").font(.callout).foregroundStyle(.secondary).fixedSize()
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(roots, id: \.path) { root in
                        HStack(spacing: 14) {
                            Image(systemName: "folder.fill").font(.title3).foregroundStyle(DiskSiftTheme.node)
                                .frame(width: 38, height: 38)
                                .background(DiskSiftTheme.node.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent).font(.callout.weight(.semibold))
                                Text(root.path.abbreviatingHome).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button { NSWorkspace.shared.open(root) } label: { Image(systemName: "arrow.up.right") }
                                .help("Open in Finder").accessibilityLabel("Open \(root.lastPathComponent) in Finder")
                            Button { model.removeScanRoot(root) } label: { Image(systemName: "minus") }
                                .help("Stop scanning this folder; files are kept")
                                .accessibilityLabel("Remove \(root.lastPathComponent) from scan locations")
                        }.padding(14)
                        Divider().padding(.leading, 66)
                    }
                    if roots.isEmpty {
                        ReviewEmptyState(title: search.isEmpty ? "Add your folders" : "No matching locations",
                                         detail: search.isEmpty ? "Find projects automatically or add any folder, including Downloads." : "Try another folder name.", icon: "folder")
                    }
                }.background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            }
        }.padding(24)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 24) {
                if model.snapshot.finishedAt != .distantPast {
                    diagnostic("Last scan", value: scanDuration)
                    diagnostic("Files measured", value: model.snapshot.content.count.formatted())
                    if model.snapshot.errorsSkipped > 0 { diagnostic("Skipped", value: model.snapshot.errorsSkipped.formatted()) }
                }
                Spacer()
                Button(model.isScanning ? "Cancel Scan" : "Scan Now") {
                    model.isScanning ? model.cancelScan() : model.startScan()
                }.buttonStyle(HemdiffButtonStyle(emphasis: .primary))
                    .disabled(model.isBusy && !model.isScanning)
            }.padding(.horizontal, 28).padding(.vertical, 16).background(.bar)
                .overlay(alignment: .top) { Divider() }
        }
        .navigationTitle("Scan Locations")
        .sheet(isPresented: $findsProjects) { FindProjectsView().environmentObject(model) }
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
