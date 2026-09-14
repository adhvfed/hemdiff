import AppKit
import SwiftUI

struct MenuBarPanel: View {
    var openMainWindow: (() -> Void)?
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AppModel
    private struct ProjectOutput {
        let path: String
        let artifacts: [Artifact]
        let bytes: Int64
    }

    private var largestProjects: [ProjectOutput] {
        let grouped = Dictionary(grouping: model.snapshot.artifacts, by: { $0.repositoryCommonPath ?? $0.projectPath })
        var projects: [ProjectOutput] = []
        for (key, artifacts) in grouped {
            let bytes = artifacts.reduce(Int64(0)) { $0 + $1.allocatedBytes }
            let path = artifacts.compactMap(\.repositoryRootPath).sorted().first
                ?? artifacts.map(\.projectPath).sorted().first
                ?? key
            projects.append(ProjectOutput(path: path, artifacts: artifacts, bytes: bytes))
        }
        projects.sort { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
        return Array(projects.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image("BrandMark").resizable().scaledToFit().frame(width: 26, height: 26)
                Text("Hemdiff").font(.headline)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
            }
            if let volume = model.volume {
                VStack(alignment: .leading, spacing: 5) {
                    Text(ByteText.compact(volume.availableBytes)).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("available · \(Int((volume.usedFraction * 100).rounded()))% used").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            metric("Build output", bytes: model.snapshot.artifactBytes, icon: "shippingbox", color: DiskSiftTheme.node)
            metric("Trash estimate", bytes: model.trashSnapshot.bytes, icon: "trash", color: DiskSiftTheme.rust, available: model.trashSnapshot.hasEstimate)
            if !model.trashSnapshot.unavailableRoots.isEmpty { Text("Trash access is restricted").font(.caption).foregroundStyle(.orange) }
            if model.isShowingSetup {
                Text("Finish setup in Hemdiff to start scanning.").font(.caption).foregroundStyle(.secondary)
            } else {
                Button {
                    model.requestQuickCleanup()
                    showMainWindow()
                } label: {
                    Label("Clean Build Output…", systemImage: "shippingbox")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(HemdiffButtonStyle(emphasis: .primary)).tint(DiskSiftTheme.node)
                    .disabled(model.snapshot.artifacts.isEmpty || model.isCleanupBlocked || model.isReviewingDeletion)
                if !largestProjects.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Largest projects").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(largestProjects, id: \.path) { project in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(URL(fileURLWithPath: project.path).lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1).truncationMode(.middle)
                                    Text(project.path.abbreviatingHome)
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .help(project.path.abbreviatingHome)
                                Text(ByteText.compact(project.bytes))
                                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                    .fixedSize()
                                Button {
                                    model.requestCleanup(project.artifacts)
                                    showMainWindow()
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 28, height: 30)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.borderless).foregroundStyle(DiskSiftTheme.node)
                                    .help("Clean build output for \(project.path.abbreviatingHome)…")
                                    .accessibilityLabel("Clean build output for \(project.path.abbreviatingHome)")
                                    .disabled(model.isCleanupBlocked || model.isReviewingDeletion)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Open Hemdiff") { showMainWindow() }.keyboardShortcut(.defaultAction)
                Spacer()
                Button(model.isScanning ? "Cancel Scan" : "Scan Now") { model.isScanning ? model.cancelScan() : model.startScan() }.disabled(!model.isScanning && (model.isBusy || model.isShowingSetup || model.isReviewingDeletion))
            }
        }.padding(20).frame(width: 350).buttonStyle(HemdiffButtonStyle())
    }
    private func showMainWindow() {
        if let openMainWindow { openMainWindow() }
        else { MainWindow.show(using: openWindow) }
    }

    private func metric(_ name: String, bytes: Int64, icon: String, color: Color, available: Bool = true) -> some View {
        HStack {
            Label(name, systemImage: icon).foregroundStyle(color)
            Spacer()
            Text(available ? ByteText.string(bytes) : "—").fontWeight(.semibold).monospacedDigit()
        }.font(.callout)
    }
}
