import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DiskSift")
                            .font(.headline)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image("MenuBarIcon")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .foregroundStyle(DiskSiftTheme.node)
                        .frame(width: 25, height: 25)
                }

                if let volume = model.volume {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(Int((volume.usedFraction * 100).rounded()))% used")
                                .font(.title2.weight(.bold))
                                .monospacedDigit()
                            Spacer()
                            Text("\(ByteText.compact(volume.availableBytes)) free")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        StorageRail(
                            volume: volume,
                            rustBytes: model.snapshot.bytes(for: .rustTarget),
                            nodeBytes: model.snapshot.bytes(for: .nodeModules)
                        )
                        .frame(height: 14)
                    }
                }

                HStack {
                    ArtifactIcon(kind: .rustTarget, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Rust target")
                            .font(.caption)
                        Text(ByteText.compact(model.snapshot.bytes(for: .rustTarget)))
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                    }
                    Spacer()
                    ArtifactIcon(kind: .nodeModules, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("node_modules")
                            .font(.caption)
                        Text(ByteText.compact(model.snapshot.bytes(for: .nodeModules)))
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }
            .padding(18)

            Divider()

            HStack {
                Button("Open DiskSift") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(.defaultAction)

                Spacer()

                Button(model.isScanning ? "Cancel" : "Scan Now") {
                    model.isScanning ? model.cancelScan() : model.startScan()
                }
            }
            .padding(14)
            .background(.bar)
        }
        .frame(width: 330)
    }

    private var statusText: String {
        if model.isScanning, let progress = model.scanProgress {
            return "Scanning · \(progress.entriesVisited.formatted()) entries"
        }
        guard model.snapshot.finishedAt != .distantPast else {
            return "Preparing first inventory"
        }
        return "Updated \(model.snapshot.finishedAt.formatted(.relative(presentation: .named)))"
    }
}
